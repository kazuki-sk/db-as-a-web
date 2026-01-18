// tools/compile_assets.js
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const mime = require('mime-types'); // npm install mime-types

const ASSET_DIR = './public'; // フロントエンドのソース
const OUTPUT_FILE = './docker/initdb/02_assets.sql';

console.log(`Building assets from ${ASSET_DIR}...`);

let sql = `TRUNCATE TABLE web_assets;
INSERT INTO web_assets (path, content_type, etag, content) VALUES
`;
const values = [];

function walkDir(dir) {
    const files = fs.readdirSync(dir);
    files.forEach(file => {
        const filePath = path.join(dir, file);
        const stat = fs.statSync(filePath);
        
        if (stat.isDirectory()) {
            walkDir(filePath);
        } else {
            // path.relative を使うことで、ASSET_DIR からの相対パスを取得する
            let relativePath = path.relative(ASSET_DIR, filePath);
            
            // Windowsのパス区切り(\)をWeb用(/)に置換
            relativePath = relativePath.split(path.sep).join('/');
            
            // 先頭に / をつけて完成
            let webPath = '/' + relativePath;
            if (!webPath.startsWith('/')) webPath = '/' + webPath;

            // 2. MIMEタイプ判定
            const contentType = mime.lookup(filePath) || 'application/octet-stream';

            // 3. バイナリ読み込み & Hexエンコード (Postgres BYTEA形式: \xDEADBEEF...)
            const buffer = fs.readFileSync(filePath);
            const hexContent = '\\x' + buffer.toString('hex');

            // 4. ETag生成 (MD5)
            const etag = crypto.createHash('md5').update(buffer).digest('hex');

            values.push(`('${webPath}', '${contentType}', '${etag}', '${hexContent}')`);
            console.log(`Packed: ${webPath} (${(stat.size / 1024).toFixed(2)} KB)`);
        }
    });
}

walkDir(ASSET_DIR);

if (values.length > 0) {
    sql += values.join(',\n') + ';';
    fs.writeFileSync(OUTPUT_FILE, sql);
    console.log(`Done! SQL generated at ${OUTPUT_FILE}`);
} else {
    console.log("No assets found.");
}
