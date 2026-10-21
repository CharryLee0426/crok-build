#!/bin/sh
# Vercel's build command (vercel.json).
#
# With CONVEX_DEPLOY_KEY (a production or preview deploy key), push the Convex functions and build the web app against
# that deployment, which `convex deploy` passes in as NEXT_PUBLIC_CONVEX_URL. Without one, only build the web app,
# against the deployment NEXT_PUBLIC_CONVEX_URL names (for a site that fronts a dev deployment; push its functions
# with `npx convex dev`). A Preview build is a test build: when the project gives it no deployment, it fronts the
# development relay (environments/dev.env), never production.
set -e
if [ -n "$CONVEX_DEPLOY_KEY" ]; then
  exec npx convex deploy --cmd 'npm run build'
fi
if [ -z "$NEXT_PUBLIC_CONVEX_URL" ] && [ "$VERCEL_ENV" = preview ]; then
  NEXT_PUBLIC_CONVEX_URL="$(sed -n 's/^CONVEX_URL=//p' environments/dev.env | tail -n 1)"
  export NEXT_PUBLIC_CONVEX_URL
  echo "Preview build against the development relay, $NEXT_PUBLIC_CONVEX_URL (environments/dev.env)."
fi
if [ -z "$NEXT_PUBLIC_CONVEX_URL" ]; then
  echo "Set CONVEX_DEPLOY_KEY (to deploy Convex too) or NEXT_PUBLIC_CONVEX_URL (to build against an existing deployment)." >&2
  exit 1
fi
# Without the Clerk keys the build succeeds and every page fails when it is served.
if [ -z "$NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY" ] || [ -z "$CLERK_SECRET_KEY" ]; then
  echo "This ${VERCEL_ENV:-local} build has no NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY or CLERK_SECRET_KEY: run relay/scripts/vercel-keys.sh test (or prod) for the project's Production and Preview variables." >&2
  exit 1
fi
exec npm run build
