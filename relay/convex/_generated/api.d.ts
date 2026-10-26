/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as bridge from "../bridge.js";
import type * as commands from "../commands.js";
import type * as crons from "../crons.js";
import type * as deviceAuth from "../deviceAuth.js";
import type * as devices from "../devices.js";
import type * as http from "../http.js";
import type * as lib_auth from "../lib/auth.js";
import type * as lib_crypto from "../lib/crypto.js";
import type * as lib_o11y_grafana from "../lib/o11y/grafana.js";
import type * as lib_o11y_i18n from "../lib/o11y/i18n.js";
import type * as lib_o11y_pages from "../lib/o11y/pages.js";
import type * as lib_o11y_read from "../lib/o11y/read.js";
import type * as lib_o11y_types from "../lib/o11y/types.js";
import type * as lib_projects from "../lib/projects.js";
import type * as lib_starting from "../lib/starting.js";
import type * as maintenance from "../maintenance.js";
import type * as o11y from "../o11y.js";
import type * as sessions from "../sessions.js";
import type * as users from "../users.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  bridge: typeof bridge;
  commands: typeof commands;
  crons: typeof crons;
  deviceAuth: typeof deviceAuth;
  devices: typeof devices;
  http: typeof http;
  "lib/auth": typeof lib_auth;
  "lib/crypto": typeof lib_crypto;
  "lib/o11y/grafana": typeof lib_o11y_grafana;
  "lib/o11y/i18n": typeof lib_o11y_i18n;
  "lib/o11y/pages": typeof lib_o11y_pages;
  "lib/o11y/read": typeof lib_o11y_read;
  "lib/o11y/types": typeof lib_o11y_types;
  "lib/projects": typeof lib_projects;
  "lib/starting": typeof lib_starting;
  maintenance: typeof maintenance;
  o11y: typeof o11y;
  sessions: typeof sessions;
  users: typeof users;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
