#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

echo "Starting deployment script..."

# 1. Identify which adapter directories have changed
CHANGED_ADAPTERS=$(git diff --name-only HEAD~1 HEAD | grep '^adapters/' | awk -F'/' '{print $1 "/" $2}' | uniq)

if [ -z "$CHANGED_ADAPTERS" ]; then
  echo "No adapters were changed. Nothing to deploy."
  exit 0
fi

echo "Found changed adapters to deploy:"
echo "$CHANGED_ADAPTERS"

# 2. Install the AWS SDK once, globally for the job
echo "Installing @aws-sdk/client-s3 with Bun..."
bun add @aws-sdk/client-s3

# 3. Loop through each changed directory and process it
for adapter_dir in $CHANGED_ADAPTERS; do
  if [ -f "$adapter_dir/package.json" ]; then
      echo "Processing: $adapter_dir"
    ( # Start a subshell to safely change directories
      cd "$adapter_dir"

      # Extract adapter ID and version from adapter.json
      ADAPTER_JSON="src/adapter.json"
      if [ ! -f "$ADAPTER_JSON" ]; then
        echo "❌ src/adapter.json not found in ${adapter_dir}."
        exit 1
      fi
      adapter_id=$(jq -r '.id // ""' "$ADAPTER_JSON")
      adapter_version=$(jq -r '.version // ""' "$ADAPTER_JSON")
      if [ -z "$adapter_id" ] || [ -z "$adapter_version" ]; then
        echo "❌ Required fields 'id' or 'version' missing in ${ADAPTER_JSON}."
        exit 1
      fi
      R2_OBJECT_KEY_JS="${adapter_id}/index.js"

      # Install local dependencies
      echo "Installing dependencies..."
      bun install

      # Build the asset
      echo "Building asset..."
      bun run build || echo "No build script or build failed"

      SOURCE_FILE_JS="dist/index.js"
      if [ ! -f "$SOURCE_FILE_JS" ]; then
        echo "❌ Build artifact not found at $SOURCE_FILE_JS."
        exit 1
      fi

      # Create a temporary JS script to upload the file
      cat << EOF > r2-upload.js
      const fs = require('fs');
      const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3');

      (async () => {
        const client = new S3Client({
          region: 'auto',
          endpoint: \`https://\${process.env.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com\`,
          credentials: {
            accessKeyId: process.env.AWS_ACCESS_KEY_ID,
            secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY,
          },
        });

        const bucket = process.env.R2_ADAPTERS_BUCKET;

        // Upload index.js
        const jsContent = fs.readFileSync('${SOURCE_FILE_JS}');
        await client.send(new PutObjectCommand({
          Bucket: bucket,
          Key: '${R2_OBJECT_KEY_JS}',
          Body: jsContent,
          ContentType: 'application/javascript',
        }));
        console.log('Uploaded index.js');
      })();
EOF

      # Execute the upload script with Bun
      echo "Uploading ${adapter_id}/index.js to R2..."
      bun run r2-upload.js

      # Clean up the temporary script
      rm -f r2-upload.js

    ) # End the subshell
  fi
done

echo "Deployment script finished successfully."
