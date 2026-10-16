#!/bin/sh
# Vercel's build command (vercel.json).
#
# With CONVEX_DEPLOY_KEY (a production or preview deploy key), push the Convex functions and build the web app against
# that deployment, which `convex deploy` passes in as NEXT_PUBLIC_CONVEX_URL. Without one, only build the web app,
# against the deployment NEXT_PUBLIC_CONVEX_URL names (for a site that fronts a dev deployment; push its functions
# with `npx convex dev`).
set -e
if [ -n "$CONVEX_DEPLOY_KEY" ]; then
  exec npx convex deploy --cmd 'npm run build'
fi
if [ -z "$NEXT_PUBLIC_CONVEX_URL" ]; then
  echo "Set CONVEX_DEPLOY_KEY (to deploy Convex too) or NEXT_PUBLIC_CONVEX_URL (to build against an existing deployment)." >&2
  exit 1
fi
exec npm run build
