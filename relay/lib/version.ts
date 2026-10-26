import "server-only";
import pkg from "../package.json";

/**
 * The web app's version for Profile › Version: the crok release this relay ships with and the deployed commit, fixed
 * at build time by next.config.ts (`CROK_WEB_VERSION`); package.json's when the build had neither.
 */
export function webVersion(): string {
  return process.env.CROK_WEB_VERSION || pkg.version;
}
