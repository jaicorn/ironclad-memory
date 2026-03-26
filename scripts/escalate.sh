#!/usr/bin/env bash
set -euo pipefail

# escalate.sh — Todo decay watchdog.
# Reads the commitment ledger, calculates staleness, applies escalating interventions.
# Uses Python for all date math — portable across macOS and Linux.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_workspace() {
  if [[ -n "${IRONCLAD_WORKSPACE:-}" ]]; then
    echo "$IRONCLAD_WORKSPACE"
    return
  fi
  local dir
  dir="$(cd "$SCRIPT_DIR/.." && pwd)"
  if [[ -d "$dir/.ironclad" ]]; then echo "$dir"; return; fi
  local check="$dir"
  while [[ "$check" != "/" ]]; do
    if [[ -d "$check/.ironclad" ]]; then echo "$check"; return; fi
    check="$(dirname "$check")"
  done
  check="$(pwd)"
  while [[ "$check" != "/" ]]; do
    if [[ -d "$check/.ironclad" ]]; then echo "$check"; return; fi
    check="$(dirname "$check")"
  done
  echo "$dir"
}

WORKSPACE="$(detect_workspace)"
LEDGER="${IRONCLAD_LEDGER_PATH:-$WORKSPACE/data/commitments/ledger.jsonl}"
ESCALATION_DIR="$WORKSPACE/data/escalations"

usage() {
  cat <<'EOF'
Usage:
  escalate.sh [options]

Scan the commitment ledger for stale items and generate escalation reports.

Tier system:
  Day 3+   Micro-step (smallest possible next action)
  Day 5+   Callout (do it or kill it)
  Day 7+   Force decision (do today / reschedule / kill / delegate)
  Day 10+  Rotting (red alert)

Options:
  --json              Output rot report as JSON only
  --report-dir PATH   Custom escalation report directory
  --dry-run           Print analysis without writing reports
  -h, --help          Show help
EOF
}

json_only=0
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)       json_only=1; shift ;;
    --report-dir) ESCALATION_DIR="$2"; shift 2 ;;
    --dry-run)    dry_run=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ $dry_run -eq 0 ]] && mkdir -p "$ESCALATION_DIR"

if [[ ! -s "$LEDGER" ]]; then
  if [[ $json_only -eq 1 ]]; then
    echo '{"rotting_items":[],"total_rot_days":0,"trend":"stable"}'
  else
    echo "Ledger is empty. Nothing to escalate."
  fi
  exit 0
fi

python3 - "$LEDGER" "$ESCALATION_DIR" "$json_only" "$dry_run" <<'PY'
import json, sys, os
from datetime import datetime, timezone, timedelta

ledger_path, escalation_dir, json_only_str, dry_run_str = sys.argv[1:5]
json_only = json_only_str == "1"
dry_run = dry_run_str == "1"

now = datetime.now(timezone.utc)
today = now.strftime("%Y-%m-%d")

# Read open entries
closed_statuses = {"done_unverified", "verified_done", "archived", "deferred", "dropped"}
entries = []

with open(ledger_path, 'r') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("status") in closed_statuses:
            continue
        entries.append(entry)

if not entries:
    if json_only:
        print(json.dumps({"rotting_items": [], "total_rot_days": 0, "trend": "stable"}))
    else:
        print("No active items. Nothing to escalate.")
    sys.exit(0)


def detect_task_type(summary):
    """Detect task type from summary text."""
    text = summary.lower()
    if any(w in text for w in ("follow up", "follow-up", "waiting", "callback")):
        return "waiting"
    if any(w in text for w in ("visit", "branch", "in-person", "in person", "drive to")):
        return "in-person"
    if any(w in text for w in ("email", "reimbursement", "draft", "send message")):
        return "email"
    if any(w in text for w in ("upload", "portal", "submit", "login", "log in")):
        return "portal"
    if any(w in text for w in ("phone", "call ", "called ", "dial")):
        return "call"
    if any(w in text for w in ("order", "buy", "purchase", "shopping")):
        return "purchase"
    return "general"


def generate_micro_step(summary, task_type):
    """Generate the smallest possible next action by task type."""
    steps = {
        "call": "Pick up the phone and dial. Say: 'Hi, I'm following up on this matter. Can you help me resolve this today?'",
        "portal": "Open the portal/website, log in, and locate the upload or submit button. Have the document ready.",
        "email": "Open your email, click compose, type the recipient. Write one sentence describing what you need.",
        "purchase": "Open the store, search for the item, add to cart. Don't overthink — just order it.",
        "in-person": "Check the hours right now, then add a calendar block. It takes 15 minutes once you're there.",
        "waiting": "Send a follow-up right now: 'Hi, checking in on this. Any update?' Takes 60 seconds.",
        "general": "Open the relevant app or document and spend exactly 2 minutes making progress. Just start.",
    }
    return steps.get(task_type, steps["general"])


def generate_decision_prompt(summary, days_stale):
    """Force a decision after enough rot."""
    return f"""DECISION REQUIRED — "{summary}" is {days_stale} days old.
  1. DO TODAY — Block 30 min right now and finish it.
  2. RESCHEDULE — Pick a specific date (not "later"). Why not today?
  3. KILL — This no longer matters. Remove it and move on.
  4. DELEGATE — Who can do this? Assign them now with a clear ask."""


# Process entries
tier_micro = []
tier_callout = []
tier_decision = []
tier_rotting = []
total_rot_days = 0

for entry in entries:
    updated = entry.get("updated_at", entry.get("created_at", ""))
    try:
        dt = datetime.fromisoformat(updated.replace("Z", "+00:00"))
        days_stale = (now - dt).days
    except (ValueError, AttributeError):
        days_stale = 0

    if days_stale < 3:
        continue

    task_type = detect_task_type(entry["summary"])
    micro_step = generate_micro_step(entry["summary"], task_type)
    due_str = f" due={entry['due_date']}" if entry.get("due_date") else ""

    item = {
        "id": entry["id"],
        "summary": entry["summary"],
        "status": entry["status"],
        "priority": entry.get("priority", "p3"),
        "owner": entry.get("owner", ""),
        "days_stale": days_stale,
        "task_type": task_type,
        "micro_step": micro_step,
        "due_date": entry.get("due_date"),
    }

    if days_stale >= 10:
        rot_days = days_stale - 10
        total_rot_days += rot_days
        item["rot_days"] = rot_days
        item["decision_prompt"] = generate_decision_prompt(entry["summary"], days_stale)
        tier_rotting.append(item)
    elif days_stale >= 7:
        item["decision_prompt"] = generate_decision_prompt(entry["summary"], days_stale)
        tier_decision.append(item)
    elif days_stale >= 5:
        tier_callout.append(item)
    elif days_stale >= 3:
        tier_micro.append(item)


# --- JSON output ---
if json_only:
    # Read previous trend
    rot_report_path = os.path.join(escalation_dir, "rot-report.json") if not dry_run else ""
    trend = "stable"
    if rot_report_path and os.path.isfile(rot_report_path):
        try:
            with open(rot_report_path) as f:
                prev = json.loads(f.read())
            if prev.get("last_run") == today:
                trend = prev.get("trend", "stable")
            else:
                prev_total = prev.get("total_rot_days", 0)
                if total_rot_days > prev_total:
                    trend = "worsening"
                elif total_rot_days < prev_total:
                    trend = "improving"
        except Exception:
            pass

    result = {
        "last_run": today,
        "rotting_items": [{"id": i["id"], "summary": i["summary"], "days_stale": i["days_stale"],
                          "rot_days": i.get("rot_days", 0), "task_type": i["task_type"]} for i in tier_rotting],
        "total_rot_days": total_rot_days,
        "trend": trend,
        "tier_counts": {
            "micro_step": len(tier_micro),
            "callout": len(tier_callout),
            "decision": len(tier_decision),
            "rotting": len(tier_rotting),
        },
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))

    # Write rot report
    if not dry_run and escalation_dir:
        os.makedirs(escalation_dir, exist_ok=True)
        with open(os.path.join(escalation_dir, "rot-report.json"), 'w') as f:
            json.dump(result, f, indent=2)
    sys.exit(0)


# --- Markdown report ---
def render_item(item, show_decision=False):
    """Render a single item as markdown."""
    lines = []
    due = f" due={item['due_date']}" if item.get("due_date") else ""
    lines.append(f"### {item['summary']} — {item['days_stale']} days stale")
    lines.append(f"**ID:** {item['id']} | **Type:** {item['task_type']} | "
                 f"**Priority:** {item['priority']} | **Status:** {item['status']}{due}")
    lines.append(f"**Micro-step:** {item['micro_step']}")
    if item.get("rot_days") is not None:
        lines.append(f"**ROT COUNTER:** {item['rot_days']} days rotting")
    if show_decision and item.get("decision_prompt"):
        lines.append("")
        lines.append(item["decision_prompt"])
    lines.append("")
    return "\n".join(lines)


report_lines = [f"# Escalation Report — {today}", ""]

total_items = len(tier_micro) + len(tier_callout) + len(tier_decision) + len(tier_rotting)
if total_items == 0:
    report_lines.append("No stale items found.")
else:
    if tier_rotting:
        report_lines.append(f"## 🔴 Rotting ({len(tier_rotting)} items, 10+ days)")
        report_lines.append("")
        for item in tier_rotting:
            report_lines.append(render_item(item, show_decision=True))

    if tier_decision:
        report_lines.append(f"## 🟡 Decision Required ({len(tier_decision)} items, 7+ days)")
        report_lines.append("")
        for item in tier_decision:
            report_lines.append(render_item(item, show_decision=True))

    if tier_callout:
        report_lines.append(f"## 🟠 Callout ({len(tier_callout)} items, 5+ days)")
        report_lines.append("")
        for item in tier_callout:
            report_lines.append(render_item(item))
            report_lines.append(f"This task is {item['days_stale']} days old. "
                              "The micro-step above takes less than 5 minutes. Do it now or kill it.\n")

    if tier_micro:
        report_lines.append(f"## 🔵 Micro-step Added ({len(tier_micro)} items, 3+ days)")
        report_lines.append("")
        for item in tier_micro:
            report_lines.append(render_item(item))

report_lines.extend(["---", f"*Generated by ironclad escalate on {today}*"])
report = "\n".join(report_lines)

if dry_run:
    print(report)
else:
    # Write report file
    os.makedirs(escalation_dir, exist_ok=True)
    report_path = os.path.join(escalation_dir, f"{today}.md")
    with open(report_path, 'w') as f:
        f.write(report)

    # Write rot report JSON
    trend = "stable"
    rot_report_path = os.path.join(escalation_dir, "rot-report.json")
    if os.path.isfile(rot_report_path):
        try:
            with open(rot_report_path) as f:
                prev = json.loads(f.read())
            if prev.get("last_run") == today:
                trend = prev.get("trend", "stable")
            else:
                prev_total = prev.get("total_rot_days", 0)
                if total_rot_days > prev_total:
                    trend = "worsening"
                elif total_rot_days < prev_total:
                    trend = "improving"
        except Exception:
            pass

    rot_data = {
        "last_run": today,
        "rotting_items": [{"id": i["id"], "summary": i["summary"], "days_stale": i["days_stale"],
                          "rot_days": i.get("rot_days", 0), "task_type": i["task_type"]} for i in tier_rotting],
        "total_rot_days": total_rot_days,
        "trend": trend,
        "tier_counts": {
            "micro_step": len(tier_micro),
            "callout": len(tier_callout),
            "decision": len(tier_decision),
            "rotting": len(tier_rotting),
        },
    }
    with open(rot_report_path, 'w') as f:
        json.dump(rot_data, f, indent=2)

    print(f"Escalation complete for {today}")
    print(f"  Report: {report_path}")
    print(f"  Rot report: {rot_report_path}")
    print(f"  Items: micro={len(tier_micro)} callout={len(tier_callout)} "
          f"decision={len(tier_decision)} rotting={len(tier_rotting)}")
    print(f"  Total rot-days: {total_rot_days}")
    print(f"  Trend: {trend}")
PY
