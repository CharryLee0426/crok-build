import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

crons.interval("mark offline hosts, fail unanswered commands", { minutes: 1 }, internal.maintenance.sweep, {});
crons.daily("prune sessions idle for 30 days", { hourUTC: 4, minuteUTC: 20 }, internal.maintenance.pruneOldSessions, {});

export default crons;
