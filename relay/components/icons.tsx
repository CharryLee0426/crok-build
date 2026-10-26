import type { ReactNode, SVGProps } from "react";

type IconProps = SVGProps<SVGSVGElement> & { size?: number };

function Icon({ size = 18, children, ...rest }: IconProps & { children: ReactNode }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.8}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...rest}
    >
      {children}
    </svg>
  );
}

export const SearchIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="11" cy="11" r="6.5" />
    <path d="m20 20-4.2-4.2" />
  </Icon>
);
export const PinIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M9 4h6l-1 5 3 3v2H7v-2l3-3-1-5Z" />
    <path d="M12 14v6" />
  </Icon>
);
export const ArchiveIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="3.5" y="4.5" width="17" height="4" rx="1" />
    <path d="M5 8.5v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-9" />
    <path d="M10 12.5h4" />
  </Icon>
);
export const UnarchiveIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="3.5" y="4.5" width="17" height="4" rx="1" />
    <path d="M5 8.5v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-9" />
    <path d="m9.5 14.5 2.5-2.5 2.5 2.5M12 12v5" />
  </Icon>
);
export const StopIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="6.5" y="6.5" width="11" height="11" rx="2" fill="currentColor" stroke="none" />
  </Icon>
);
export const SendIcon = (p: IconProps) => (
  <Icon {...p} strokeWidth={2.1}>
    <path d="M12 19V5M5.5 11.5 12 5l6.5 6.5" />
  </Icon>
);
export const InfoIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M12 11v5.5M12 7.6v.1" />
  </Icon>
);
export const ChevronLeftIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="m14.5 5.5-6.5 6.5 6.5 6.5" />
  </Icon>
);
export const ChevronDownIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="m6 9.5 6 6 6-6" />
  </Icon>
);
export const ChevronRightIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="m9.5 6 6 6-6 6" />
  </Icon>
);
export const ArrowDownIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 5v14M6 13l6 6 6-6" />
  </Icon>
);
export const ArrowUpIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 19V5M6 11l6-6 6 6" />
  </Icon>
);
/** A project section's header. */
export const FolderIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M3.5 7.5a2 2 0 0 1 2-2h3.6l2 2.2h7.4a2 2 0 0 1 2 2v7.8a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2V7.5Z" />
  </Icon>
);
/** Six dots: a drag handle. */
export const GripIcon = (p: IconProps) => (
  <Icon {...p}>
    {[8.5, 15.5].map((x) =>
      [6, 12, 18].map((y) => <circle key={`${x}-${y}`} cx={x} cy={y} r="1.4" fill="currentColor" stroke="none" />),
    )}
  </Icon>
);
/** "Sort by recent activity": a clock turning back. */
export const RecentIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3" />
    <path d="M4.5 4.5v3.2h3.2" />
    <path d="M12 8v4l2.6 1.6" />
  </Icon>
);
/** "New session" in a project section. */
export const PlusIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 5.5v13M5.5 12h13" />
  </Icon>
);
/** The list toolbar's compose button (Telegram's "new message"): a pencil on a square. */
export const ComposeIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M11 4.5H6.5a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2V13" />
    <path d="M17.6 3.9a2 2 0 0 1 2.8 2.8L12.5 14.6 9 15.5l.9-3.5 7.7-8.1Z" />
  </Icon>
);
/** ☰: the composer's Menu button (Telegram's bot menu). */
export const MenuIcon = (p: IconProps) => (
  <Icon {...p} strokeWidth={2}>
    <path d="M5 7h14M5 12h14M5 17h14" />
  </Icon>
);
export const MoreIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="5.5" cy="12" r="1.2" fill="currentColor" />
    <circle cx="12" cy="12" r="1.2" fill="currentColor" />
    <circle cx="18.5" cy="12" r="1.2" fill="currentColor" />
  </Icon>
);
export const CheckIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="m5 12.5 4.5 4.5L19 7.5" />
  </Icon>
);
export const DoubleCheckIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="m2.5 12.5 4.5 4.5 9.5-9.5" />
    <path d="m11.5 16 1 1 9.5-9.5" />
  </Icon>
);
export const ClockIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="8" />
    <path d="M12 7.5V12l3 2" />
  </Icon>
);
export const AlertIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="9" fill="currentColor" stroke="none" />
    <path d="M12 7.5v5.5M12 16.3v.2" stroke="var(--surface)" strokeWidth={2.2} />
  </Icon>
);
export const WarningIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M10.3 4.3 2.8 17.5A2 2 0 0 0 4.5 20.5h15a2 2 0 0 0 1.7-3L13.7 4.3a2 2 0 0 0-3.4 0Z" />
    <path d="M12 9.5v4.5M12 17.2v.1" />
  </Icon>
);
export const ComputerIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="3.5" y="5" width="17" height="11" rx="1.6" />
    <path d="M2 19h20" />
  </Icon>
);
export const PhoneIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="6.5" y="2.5" width="11" height="19" rx="2.4" />
    <path d="M11 18.5h2" />
  </Icon>
);
export const GlobeIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M3.5 12h17M12 3.5c2.3 2.4 3.5 5.2 3.5 8.5s-1.2 6.1-3.5 8.5c-2.3-2.4-3.5-5.2-3.5-8.5S9.7 5.9 12 3.5Z" />
  </Icon>
);
export const LinkIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M10 14a4 4 0 0 0 5.7 0l3.1-3.1a4 4 0 0 0-5.7-5.7L11.6 6.7" />
    <path d="M14 10a4 4 0 0 0-5.7 0l-3.1 3.1a4 4 0 0 0 5.7 5.7l1.5-1.5" />
  </Icon>
);
export const ChatsIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4 5.5h12a1.5 1.5 0 0 1 1.5 1.5v7A1.5 1.5 0 0 1 16 15.5H9l-4 3.5v-3.5H4A1.5 1.5 0 0 1 2.5 14V7A1.5 1.5 0 0 1 4 5.5Z" />
    <path d="M17.5 9H20a1.5 1.5 0 0 1 1.5 1.5V17a1.5 1.5 0 0 1-1.5 1.5h-1V21l-3.2-2.5H12" />
  </Icon>
);
export const DevicesIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="2.5" y="4.5" width="13" height="9.5" rx="1.4" />
    <path d="M5.5 17.5h7" />
    <rect x="16" y="8" width="5.5" height="11.5" rx="1.3" />
  </Icon>
);
export const XIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M6 6l12 12M18 6 6 18" />
  </Icon>
);
export const CopyIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="8.5" y="8.5" width="11" height="11" rx="2" />
    <path d="M15.5 8.5V6a1.5 1.5 0 0 0-1.5-1.5H6A1.5 1.5 0 0 0 4.5 6v8A1.5 1.5 0 0 0 6 15.5h2.5" />
  </Icon>
);
export const PencilIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4.5 19.5h4l10-10a2.8 2.8 0 0 0-4-4l-10 10v4Z" />
    <path d="m13 7 4 4" />
  </Icon>
);
export const SpinnerIcon = (p: IconProps) => (
  <Icon {...p} className={`spin ${p.className ?? ""}`}>
    <path d="M12 3.5a8.5 8.5 0 1 0 8.5 8.5" />
  </Icon>
);
export const PlanIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M9 6.5h11M9 12h11M9 17.5h11" />
    <path d="m3.5 6.5 1.2 1.2 2-2.2" />
    <circle cx="5" cy="12" r="1" fill="currentColor" />
    <circle cx="5" cy="17.5" r="1" fill="currentColor" />
  </Icon>
);
export const SparkIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 3.5v4M12 16.5v4M3.5 12h4M16.5 12h4M6 6l2.6 2.6M15.4 15.4 18 18M18 6l-2.6 2.6M8.6 15.4 6 18" />
  </Icon>
);
export const ShieldIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 3 4.5 6v5.5c0 4.5 3.2 8.2 7.5 9.5 4.3-1.3 7.5-5 7.5-9.5V6L12 3Z" />
    <path d="m9 12 2 2 4-4.5" />
  </Icon>
);
export const BoltIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M13 2.5 4.5 13.5H11l-1 8 8.5-11H12l1-8Z" />
  </Icon>
);

/* Tool kinds (DESIGN.md §3): read, edit, delete, move, search, execute, think, fetch, other. */
export const FileIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M6.5 3.5h7l4 4v12a1 1 0 0 1-1 1h-10a1 1 0 0 1-1-1v-15a1 1 0 0 1 1-1Z" />
    <path d="M13.5 3.5v4h4" />
  </Icon>
);
export const TrashIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4.5 7h15M9.5 7V4.5h5V7M6.5 7l1 12.5h9l1-12.5" />
  </Icon>
);
export const MoveIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4 12h15M14.5 7.5 19 12l-4.5 4.5" />
  </Icon>
);
export const TerminalIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="3" y="4.5" width="18" height="15" rx="2" />
    <path d="m7 9.5 3 2.5-3 2.5M12.5 15h4.5" />
  </Icon>
);
export const BulbIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M9 17.5h6M10 20.5h4M12 3.5a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V17h5v-.6c0-.8.4-1.5 1-2A6 6 0 0 0 12 3.5Z" />
  </Icon>
);
export const DownloadIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 4v11M7 10.5l5 5 5-5M5 19.5h14" />
  </Icon>
);
export const WrenchIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M14.5 6.5a4 4 0 0 0 5 5l-8.8 8.8a2.1 2.1 0 0 1-3-3l8.8-8.8a4 4 0 0 0-2-2Z" />
    <path d="M14.5 6.5a4 4 0 0 1 4.6-2.9l-2.6 2.6.4 2.2 2.2.4 2.6-2.6a4 4 0 0 1-2.9 4.6" />
  </Icon>
);

export function ToolKindIcon({ kind, ...p }: IconProps & { kind?: string }) {
  switch (kind) {
    case "read":
      return <FileIcon {...p} />;
    case "edit":
      return <PencilIcon {...p} />;
    case "delete":
      return <TrashIcon {...p} />;
    case "move":
      return <MoveIcon {...p} />;
    case "search":
      return <SearchIcon {...p} />;
    case "execute":
      return <TerminalIcon {...p} />;
    case "think":
      return <BulbIcon {...p} />;
    case "fetch":
      return <DownloadIcon {...p} />;
    default:
      return <WrenchIcon {...p} />;
  }
}

/* The Telegram-style frame (mobile/DESIGN.md "Web"). */
export const ArrowLeftIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M19 12H5.5M11 5.5 4.5 12l6.5 6.5" />
  </Icon>
);
/** The model pill: a chip (iOS `cpu`). */
export const ChipIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="6.5" y="6.5" width="11" height="11" rx="2" />
    <rect x="9.5" y="9.5" width="5" height="5" rx="0.8" />
    <path d="M9.5 3.5v3M14.5 3.5v3M9.5 17.5v3M14.5 17.5v3M3.5 9.5h3M3.5 14.5h3M17.5 9.5h3M17.5 14.5h3" />
  </Icon>
);
/** The thinking pill: a brain (iOS `brain`). */
export const BrainIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 5.5v13M12 5.5A3 3 0 0 0 6.3 4.8 3 3 0 0 0 4 9a3.2 3.2 0 0 0 .3 5.6A3.3 3.3 0 0 0 8 19.6a2.9 2.9 0 0 0 4-1.1" />
    <path d="M12 5.5a3 3 0 0 1 5.7-.7A3 3 0 0 1 20 9a3.2 3.2 0 0 1-.3 5.6 3.3 3.3 0 0 1-3.7 5 2.9 2.9 0 0 1-4-1.1" />
    <path d="M8.5 9.5c1 0 2 .6 2.3 1.6M15.5 9.5c-1 0-2 .6-2.3 1.6M7.5 14.5c.8.4 1.6.4 2.4 0M16.5 14.5c-.8.4-1.6.4-2.4 0" />
  </Icon>
);
export const BrushIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M19.5 3.5c-3 1.4-7 5.2-9.2 8.3l1.9 1.9c3.1-2.2 6.9-6.2 8.3-9.2.2-.6-.4-1.2-1-1Z" />
    <path d="M10 12.5c-2 .2-3.4 1.6-3.6 3.5-.2 1.6-.9 2.8-2.4 3.6 3.3.7 6.6-.4 7.6-2.9.3-.8.2-1.6-.1-2.4" />
  </Icon>
);
export const PhotoIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="3" y="4.5" width="18" height="15" rx="2.5" />
    <circle cx="9" cy="10" r="1.8" />
    <path d="m3.5 17.5 5-4.5 3.5 3 3-2.5 5.5 4.5" />
  </Icon>
);
/** "Mark as Read": a bubble with a check. */
export const ReadIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 4c4.7 0 8.5 3.2 8.5 7.2s-3.8 7.2-8.5 7.2c-1 0-2-.1-2.9-.4L5 19.5l1-3.4C4.5 14.8 3.5 13.1 3.5 11.2 3.5 7.2 7.3 4 12 4Z" />
    <path d="m8.5 11.3 2.4 2.4 4.6-4.7" />
  </Icon>
);
export const ReorderIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M8 19V5M4.5 8.5 8 5l3.5 3.5M16 5v14M12.5 15.5 16 19l3.5-3.5" />
  </Icon>
);

/** GitHub's mark (Simple Icons, CC0), filled. */
export const GitHubMark = ({ size = 18, ...rest }: IconProps) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" focusable="false" {...rest}>
    <path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12" />
  </svg>
);
/** X's logo (Simple Icons, CC0), filled. */
export const XLogo = ({ size = 18, ...rest }: IconProps) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" focusable="false" {...rest}>
    <path d="M18.901 1.153h3.68l-8.04 9.19L24 22.846h-7.406l-5.8-7.584-6.638 7.584H.474l8.6-9.83L0 1.154h7.594l5.243 6.932ZM17.61 20.644h2.039L6.486 3.24H4.298Z" />
  </svg>
);
