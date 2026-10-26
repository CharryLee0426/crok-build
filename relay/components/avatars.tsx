"use client";

/**
 * The avatars of mobile/DESIGN.md: a session's topic icon (Telegram's topic glyph), a computer's avatar (an account in
 * the switcher), the relay account's picture, and the Archived Sessions row's archive box.
 */
import { useId, useState } from "react";
import { lighten, nameInitials, topicColor, topicLetter } from "@/lib/computers";
import { projectHue } from "@/lib/format";
import { ArchiveIcon } from "./icons";

/**
 * A speech bubble (a circle with a short tail at the bottom left) filled top to bottom with the topic colour lightened
 * 15 % → the colour, and the title's first letter in white. The colour is keyed by the session's doc id.
 */
export function TopicIcon({
  id,
  title,
  size = 40,
  dimmed = false,
  className = "",
}: {
  id: string;
  title: string;
  size?: number;
  dimmed?: boolean;
  className?: string;
}) {
  const gradient = useId();
  const color = topicColor(id);
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 100 100"
      aria-hidden="true"
      focusable="false"
      className={`shrink-0 ${dimmed ? "opacity-55 grayscale" : ""} ${className}`}
    >
      <defs>
        <linearGradient id={gradient} gradientUnits="userSpaceOnUse" x1="0" y1="3" x2="0" y2="96">
          <stop offset="0" stopColor={lighten(color, 0.15)} />
          <stop offset="1" stopColor={color} />
        </linearGradient>
      </defs>
      {/* The body (centre 0.53, 0.47, radius 0.44 of the side) and the tail, as on the phones. */}
      <g fill={`url(#${gradient})`}>
        <circle cx="53" cy="47" r="44" />
        <path d="M17 62Q19 86 5 95Q27 96 42 87Z" />
      </g>
      <text
        x="53"
        y="48"
        textAnchor="middle"
        dominantBaseline="central"
        fill="#fff"
        fontSize="44"
        fontWeight="700"
        style={{ fontFamily: 'ui-rounded, "SF Pro Rounded", system-ui, sans-serif' }}
      >
        {topicLetter(title)}
      </text>
    </svg>
  );
}

/** Initials on a hue of their own, with Telegram's green online dot. */
function InitialsAvatar({
  text,
  hue,
  size,
  online,
  dimmed,
  square = false,
}: {
  text: string;
  hue: number;
  size: number;
  online?: boolean;
  dimmed?: boolean;
  square?: boolean;
}) {
  const dot = Math.max(9, Math.round(size * 0.28));
  return (
    <span className="relative inline-flex shrink-0" style={{ width: size, height: size }}>
      <span
        className={`avatar inline-flex h-full w-full items-center justify-center font-semibold tracking-wide ${
          dimmed ? "opacity-55 grayscale" : ""
        }`}
        style={{
          ["--hue" as string]: hue,
          fontSize: Math.round(size * 0.38),
          borderRadius: square ? size * 0.3 : 9999,
        }}
        aria-hidden="true"
      >
        {text}
      </span>
      {online ? (
        <span
          className="absolute rounded-full bg-online"
          style={{ width: dot, height: dot, right: -1, bottom: -1, boxShadow: "0 0 0 2px var(--surface)" }}
        />
      ) : null}
    </span>
  );
}

/** A computer: its name's initials on a colour keyed by the device id, the online dot while online. */
export function ComputerAvatar({
  id,
  name,
  online,
  size = 36,
}: {
  id: string;
  name: string;
  online?: boolean;
  size?: number;
}) {
  return <InitialsAvatar text={nameInitials(name)} hue={projectHue(id)} size={size} online={online} />;
}

/** A project: its initials on the project colour, a rounded square on the Sessions page (Telegram's forum avatar). */
export function ForumAvatar({ path, name, size = 54, dimmed }: { path: string; name: string; size?: number; dimmed?: boolean }) {
  return <InitialsAvatar text={nameInitials(name)} hue={projectHue(path || name)} size={size} dimmed={dimmed} square />;
}

/** The relay account's picture, or its initials on the accent gradient. */
export function AccountAvatar({
  name,
  imageUrl,
  size = 32,
}: {
  name: string;
  imageUrl?: string | null;
  size?: number;
}) {
  const [failed, setFailed] = useState(false);
  if (imageUrl && !failed && /^https:\/\//.test(imageUrl)) {
    return (
      // eslint-disable-next-line @next/next/no-img-element
      <img
        src={imageUrl}
        alt=""
        width={size}
        height={size}
        referrerPolicy="no-referrer"
        onError={() => setFailed(true)}
        className="shrink-0 rounded-full object-cover"
        style={{ width: size, height: size }}
      />
    );
  }
  return (
    <span
      className="inline-flex shrink-0 items-center justify-center rounded-full font-semibold text-accent-fg"
      style={{
        width: size,
        height: size,
        fontSize: Math.round(size * 0.38),
        background: "linear-gradient(180deg, color-mix(in srgb, var(--accent) 80%, white), var(--accent))",
      }}
      aria-hidden="true"
    >
      {nameInitials(name)}
    </span>
  );
}

/** Telegram's Archived Chats avatar: a grey circle with an archive box. */
export function ArchiveAvatar({ size = 54 }: { size?: number }) {
  return (
    <span
      className="inline-flex shrink-0 items-center justify-center rounded-full text-white"
      style={{ width: size, height: size, background: "linear-gradient(180deg, #b8bcc2, #9a9ea3)" }}
      aria-hidden="true"
    >
      <ArchiveIcon size={Math.round(size * 0.44)} strokeWidth={2} />
    </span>
  );
}
