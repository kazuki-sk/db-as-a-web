-- sql/02_gateway.sql

-- ================================================================
-- 1. SECURITY & ROLES
-- ================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'web_authenticator') THEN
    CREATE ROLE web_authenticator WITH LOGIN PASSWORD 'very_secure_password' NOINHERIT;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO web_authenticator;

-- 権限設定
GRANT SELECT ON web_assets TO web_authenticator;
GRANT SELECT ON posts TO web_authenticator;
GRANT SELECT ON comments TO web_authenticator;
GRANT SELECT ON redirect_rules TO web_authenticator;
GRANT SELECT ON security_configs TO web_authenticator;
GRANT INSERT ON access_logs TO web_authenticator;
GRANT INSERT ON comments TO web_authenticator;

GRANT EXECUTE ON FUNCTION resolve_route TO web_authenticator;
GRANT EXECUTE ON FUNCTION html_escape TO web_authenticator;

-- ================================================================
-- 2. MEDIA TYPE HANDLER DEFINITION (v12 Fix)
-- ================================================================
-- PostgREST に "任意のAcceptヘッダー" を受け入れさせ、
-- かつデフォルトで Raw モード (JSON変換なし) として扱わせるためのドメイン定義
DROP DOMAIN IF EXISTS "*/*" CASCADE;
CREATE DOMAIN "*/*" AS bytea;

-- ================================================================
-- 3. GATEWAY FUNCTION (serve_raw)
-- ================================================================
-- 戻り値を BYTEA ではなく、定義した "*/*" ドメイン型にするのが最大のポイント
CREATE OR REPLACE FUNCTION serve_raw() 
RETURNS "*/*" AS $$
DECLARE
    v_res http_response;
    v_headers_arr jsonb := '[]'::jsonb;
    v_header_key text;
    v_header_value text;
BEGIN
    -- PostgREST からのリクエスト情報を取得
    v_res := resolve_route(
        req_method  => COALESCE(current_setting('request.method', true), 'GET'),
        req_path    => COALESCE(current_setting('request.path', true), '/'),
        req_headers => COALESCE(current_setting('request.headers', true)::jsonb, '{}'::jsonb),
        req_params  => COALESCE(current_setting('request.query', true)::jsonb, '{}'::jsonb),
        req_payload => CASE 
                        WHEN current_setting('request.body', true) IS NULL THEN '{}'::jsonb
                        ELSE current_setting('request.body', true)::jsonb 
                       END
    );

    -- 1. ステータスコード設定
    PERFORM set_config('response.status', v_res.status_code::text, true);

    -- 2. ヘッダー配列の構築
    -- Content-Type を先頭に追加
    v_headers_arr := v_headers_arr || jsonb_build_object('Content-Type', v_res.content_type);

    -- カスタムヘッダーを追加
    IF v_res.headers IS NOT NULL THEN
        FOR v_header_key, v_header_value IN SELECT * FROM jsonb_each_text(v_res.headers)
        LOOP
            v_headers_arr := v_headers_arr || jsonb_build_object(v_header_key, v_header_value);
        END LOOP;
    END IF;

    -- 設定適用
    PERFORM set_config('response.headers', v_headers_arr::text, true);

    -- 3. 返却 (ドメイン型へキャスト)
    -- これにより PostgREST は JSON エンコードをスキップする
    RETURN v_res.content::"*/*";

EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('response.status', '500', true);
    PERFORM set_config('response.headers', '[{"Content-Type": "text/plain"}]', true);
    -- エラー時もキャストが必要
    RETURN ('Internal Gateway Error: ' || SQLERRM)::bytea::"*/*";
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION serve_raw TO web_authenticator;
