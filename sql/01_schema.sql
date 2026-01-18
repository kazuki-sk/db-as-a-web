-- ================================================================
-- 0. CLEANUP (再実行用)
-- ================================================================
DROP FUNCTION IF EXISTS resolve_route CASCADE;
DROP FUNCTION IF EXISTS log_request_autonomous CASCADE;
DROP TABLE IF EXISTS access_logs CASCADE;
DROP TABLE IF EXISTS comments CASCADE;
DROP TABLE IF EXISTS posts CASCADE;
DROP TABLE IF EXISTS web_assets CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS redirect_rules CASCADE;
DROP TABLE IF EXISTS security_configs CASCADE;
DROP TYPE IF EXISTS http_response CASCADE;

-- ================================================================
-- 1. EXTENSIONS & SCHEMA
-- ================================================================
CREATE EXTENSION IF NOT EXISTS "dblink";  -- 自律ログ用
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- 検索補助
CREATE EXTENSION IF NOT EXISTS "pgcrypto"; -- UUID/Hash用

-- レスポンス複合型
CREATE TYPE http_response AS (
    status_code INTEGER,
    content_type TEXT,
    content BYTEA,
    headers JSONB
);

-- 1.1 ユーザー管理
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    role TEXT DEFAULT 'guest',
    password_hash TEXT
);

-- 1.2 アセット & ルーティング
CREATE TABLE web_assets (
    path TEXT PRIMARY KEY,
    content BYTEA NOT NULL,
    content_type TEXT NOT NULL,
    etag TEXT,
    required_role TEXT DEFAULT 'guest',
    last_modified TIMESTAMPTZ DEFAULT now()
);

-- 1.3 コンテンツ (SSR/FTS用)
CREATE TABLE posts (
    slug TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    published_at TIMESTAMPTZ DEFAULT now(),
    fts_doc tsvector GENERATED ALWAYS AS (
        to_tsvector('simple', title || ' ' || content) 
    ) STORED
);
CREATE INDEX idx_posts_fts ON posts USING GIN(fts_doc);

-- 1.4 コメント
CREATE TABLE comments (
    id SERIAL PRIMARY KEY,
    post_slug TEXT REFERENCES posts(slug),
    author TEXT,
    body TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- 1.5 リダイレクト
CREATE TABLE redirect_rules (
    source_path TEXT PRIMARY KEY,
    destination_path TEXT NOT NULL,
    status_code INT DEFAULT 301
);

-- 1.6 セキュリティ設定
CREATE TABLE security_configs (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- 1.7 アクセスログ
CREATE TABLE access_logs (
    id BIGSERIAL PRIMARY KEY,
    request_time TIMESTAMPTZ DEFAULT clock_timestamp(),
    method TEXT,
    path TEXT,
    status_code INT,
    user_role TEXT,
    processing_ms NUMERIC,
    error_message TEXT
);

-- ================================================================
-- 2. TRIGGERS & UTILITIES
-- ================================================================

-- ETag自動更新
CREATE OR REPLACE FUNCTION generate_asset_etag() RETURNS TRIGGER AS $$
BEGIN
    NEW.etag := '"' || encode(digest(NEW.content, 'md5'), 'hex') || '"';
    NEW.last_modified := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_web_assets_etag BEFORE INSERT OR UPDATE ON web_assets
FOR EACH ROW EXECUTE FUNCTION generate_asset_etag();

-- 自律型ログ記録 (dblink修正版: 都度接続で重複エラー回避)
CREATE OR REPLACE FUNCTION log_request_autonomous(
    p_method text, p_path text, p_status int, p_role text, p_ms numeric, p_err text
) RETURNS void AS $$
DECLARE
    -- ローカル接続文字列 (パスワード不要設定を想定)
    v_conn_str text := 'dbname=' || current_database();
BEGIN
    PERFORM dblink_exec(v_conn_str, 
        format('INSERT INTO access_logs (method, path, status_code, user_role, processing_ms, error_message) VALUES (%L, %L, %s, %L, %s, %L)', 
        p_method, p_path, p_status, p_role, p_ms, p_err));
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Log failed: %', SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- 3. THE GOD FUNCTION (Router + Controller + View)
-- ================================================================

CREATE OR REPLACE FUNCTION resolve_route(
    req_method text DEFAULT 'GET',
    req_path text DEFAULT '/',
    req_headers jsonb DEFAULT '{}'::jsonb,
    req_params jsonb DEFAULT '{}'::jsonb,
    req_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS http_response AS $$
DECLARE
    -- 計測用
    v_start_time TIMESTAMPTZ := clock_timestamp();
    v_processing_ms NUMERIC;
    
    -- 変数
    v_user_role text;
    v_accept text := req_headers->>'accept';
    v_target_path text;
    v_content bytea;
    v_content_type text;
    v_status int := 200;
    v_sec_headers jsonb;
    v_redirect_url text;
    v_post_slug text;
    v_search_res text;
    
    -- 制御フラグ
    v_handled boolean := false;
BEGIN
    -- 0. 初期化
    BEGIN
        v_user_role := COALESCE(current_setting('request.jwt.claims', true)::jsonb->>'role', 'guest');
    EXCEPTION WHEN OTHERS THEN
        v_user_role := 'guest';
    END;

    SELECT jsonb_object_agg(key, value) INTO v_sec_headers FROM security_configs;

    -- 1. リダイレクト判定
    IF NOT v_handled THEN
        SELECT destination_path, status_code INTO v_redirect_url, v_status 
        FROM redirect_rules WHERE source_path = req_path;
        
        IF FOUND THEN
            v_content := NULL;
            v_content_type := 'text/plain';
            v_sec_headers := v_sec_headers || jsonb_build_object('Location', v_redirect_url);
            v_handled := true;
        END IF;
    END IF;

    -- 2. POST処理 (コメント)
    IF NOT v_handled AND req_method = 'POST' AND req_path = '/api/comments' THEN
        INSERT INTO comments (post_slug, author, body)
        VALUES (req_payload->>'slug', req_payload->>'author', req_payload->>'body');
        
        v_status := 303;
        v_redirect_url := '/blog/' || (req_payload->>'slug');
        v_content := NULL;
        v_content_type := 'text/plain';
        v_sec_headers := v_sec_headers || jsonb_build_object('Location', v_redirect_url);
        v_handled := true;
    END IF;

    -- 3. コンテンツ解決
    IF NOT v_handled THEN
        
        -- A. Admin Dashboard
        IF req_path = '/admin/dashboard' THEN
            IF v_user_role != 'admin' THEN
                v_status := 403;
                v_content := 'Forbidden'::bytea;
                v_content_type := 'text/plain';
            ELSE
                WITH stats AS (
                    SELECT 
                        count(*) as total,
                        COALESCE(avg(processing_ms), 0)::numeric(10,2) as latency
                    FROM access_logs
                )
                SELECT replace(replace(convert_from(content, 'UTF8'), '{{total}}', s.total::text), '{{latency}}', s.latency::text)::bytea
                INTO v_content
                FROM web_assets, stats s WHERE path = '/admin/dashboard.html';
                
                v_content_type := 'text/html';
            END IF;

        -- B. Search (SSR)
        ELSIF req_path = '/search' THEN
            SELECT string_agg(format('<li><a href="/blog/%s">%s</a></li>', slug, title), '')
            INTO v_search_res
            FROM posts
            WHERE fts_doc @@ to_tsquery('simple', COALESCE(req_params->>'q', ''));
            
            SELECT replace(convert_from(content, 'UTF8'), '{{results}}', COALESCE(v_search_res, 'No results'))::bytea
            INTO v_content
            FROM web_assets WHERE path = '/search.html';
            
            v_content_type := 'text/html';

        -- C. Blog & Static Logic
        ELSE
            -- 正規化
            v_target_path := CASE 
                WHEN req_path = '/' THEN '/index.html'
                WHEN req_path LIKE '/blog/%' THEN '/blog/[slug].html'
                WHEN req_path !~ '\.[a-zA-Z0-9]+$' THEN req_path || '.html'
                ELSE req_path
            END;

            -- コンテンツ取得
            IF req_path LIKE '/blog/%' THEN
                v_post_slug := substring(req_path from 7);
                
                IF v_accept LIKE '%application/json%' THEN
                    SELECT json_build_object('title', title, 'content', content)::text::bytea, 'application/json'
                    INTO v_content, v_content_type
                    FROM posts WHERE slug = v_post_slug;
                ELSE 
                    SELECT replace(replace(convert_from(a.content, 'UTF8'), '{{title}}', p.title), '{{content}}', p.content)::bytea, 'text/html'
                    INTO v_content, v_content_type
                    FROM web_assets a, posts p 
                    WHERE a.path = '/blog/[slug].html' AND p.slug = v_post_slug;
                END IF;
            ELSE
                SELECT content, content_type INTO v_content, v_content_type
                FROM web_assets WHERE path = v_target_path;
            END IF;

            -- 404 Check
            IF v_content IS NULL THEN
                SELECT content, content_type, 404 INTO v_content, v_content_type, v_status
                FROM web_assets WHERE path = '/404.html';
            END IF;
        END IF;
    END IF;

    -- 4. 終了処理
    v_processing_ms := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000;
    
    PERFORM log_request_autonomous(req_method, req_path, v_status, v_user_role, v_processing_ms, NULL);
    
    RETURN (v_status, v_content_type::text, v_content, v_sec_headers || jsonb_build_object('X-Runtime-Ms', v_processing_ms));

EXCEPTION WHEN OTHERS THEN
    v_processing_ms := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000;
    PERFORM log_request_autonomous(req_method, req_path, 500, v_user_role, v_processing_ms, SQLERRM);
    RETURN (500, 'text/plain'::text, 'Internal Server Error'::bytea, '{}'::jsonb);
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- 4. SEED DATA (初期データ)
-- ================================================================

-- Headers
INSERT INTO security_configs VALUES 
('X-Frame-Options', 'DENY'),
('X-Content-Type-Options', 'nosniff');

-- Users
INSERT INTO users (username, role) VALUES ('admin', 'admin');

-- Assets
INSERT INTO web_assets (path, content, content_type) VALUES
('/index.html', '<h1>Welcome to DB-Web</h1><p><a href="/blog/hello">Go to Blog</a></p>'::bytea, 'text/html'),
('/404.html', '<h1>404 Not Found</h1>'::bytea, 'text/html'),
('/search.html', '<h1>Search Results</h1><ul>{{results}}</ul>'::bytea, 'text/html'),
('/admin/dashboard.html', '<h1>Admin Dashboard</h1><p>Requests: {{total}}</p><p>Avg Latency: {{latency}}ms</p>'::bytea, 'text/html'),
('/blog/[slug].html', '<html><head><title>{{title}}</title></head><body><h1>{{title}}</h1><article>{{content}}</article><a href="/">Back</a></body></html>'::bytea, 'text/html');

-- Posts
INSERT INTO posts (slug, title, content) VALUES
('hello', 'Hello World', 'This is the first post served directly from PostgreSQL.'),
('db-magic', 'Why DB-as-Web?', 'Because latency is the enemy. Atomicity is our friend.');

-- Redirects
INSERT INTO redirect_rules (source_path, destination_path) VALUES
('/old-blog', '/blog/hello');
