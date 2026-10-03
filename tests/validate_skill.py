#!/usr/bin/env python3
from pathlib import Path
import json
import os
import re
import sys


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


repo_root = Path(__file__).resolve().parents[1]
skill_dir = repo_root / "skills" / "puppeteer-my-chrome"
skill_file = skill_dir / "SKILL.md"
cli_manifest_file = skill_dir / "cli" / "package.json"
cli_lock_file = skill_dir / "cli" / "package-lock.json"
root_license = repo_root / "LICENSE"
skill_license = skill_dir / "LICENSE"
macos_home_prefix = "/" + "Users" + "/"
linux_home_prefix = "/" + "home" + "/"

if not skill_file.is_file():
    fail("SKILL.md is missing")

text = skill_file.read_text(encoding="utf-8")
lines = text.splitlines()
if len(lines) >= 500:
    fail(f"SKILL.md has {len(lines)} lines; expected fewer than 500")
if not lines or lines[0] != "---":
    fail("SKILL.md must start with YAML frontmatter")

try:
    end = lines.index("---", 1)
except ValueError:
    fail("SKILL.md frontmatter is not closed")

metadata: dict[str, str] = {}
for line in lines[1:end]:
    match = re.fullmatch(r"([a-z-]+):\s*(.+)", line)
    if not match:
        fail(f"unsupported frontmatter line: {line!r}")
    metadata[match.group(1)] = match.group(2)

if set(metadata) != {"name", "description"}:
    fail("frontmatter must contain exactly name and description")

name = metadata["name"]
description = metadata["description"]
if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name):
    fail("skill name does not satisfy the Agent Skills naming rule")
if name != skill_dir.name:
    fail("skill name must match its directory")
if not 1 <= len(description) <= 1024:
    fail("description must contain 1-1024 characters")

for path in skill_dir.rglob("*"):
    if "node_modules" in path.relative_to(skill_dir).parts:
        continue
    if path.is_symlink():
        fail(f"skill contains a symlink: {path.relative_to(skill_dir)}")
    if path.is_file() and path.stat().st_size > 1_000_000:
        fail(f"skill contains a file larger than 1 MB: {path.relative_to(skill_dir)}")

for script in (skill_dir / "scripts").iterdir():
    if script.is_file():
        if script.suffix not in {".sh", ".mjs"}:
            fail(f"unsupported script type: {script.name}")
        if script.suffix == ".sh" and not os.access(script, os.X_OK):
            fail(f"script is not executable: {script.name}")

for path in skill_dir.rglob("*"):
    if "node_modules" in path.relative_to(skill_dir).parts:
        continue
    if not path.is_file():
        continue
    content = path.read_text(encoding="utf-8")
    if macos_home_prefix in content or linux_home_prefix in content:
        fail(f"machine-specific home path found in {path.relative_to(skill_dir)}")
    if re.search(r"PLAYWRIGHT_MCP_EXTENSION_TOKEN=[A-Za-z0-9_-]{32,}", content):
        fail(f"token-shaped assignment found in {path.relative_to(skill_dir)}")

if not skill_license.is_file():
    fail("the installable skill must include its license")
if skill_license.read_bytes() != root_license.read_bytes():
    fail("the installable skill license must match the repository license")

manifest = json.loads(cli_manifest_file.read_text(encoding="utf-8"))
lock = json.loads(cli_lock_file.read_text(encoding="utf-8"))
dependency_fields = [key for key in manifest if key.lower().endswith("dependencies")]
if dependency_fields != ["dependencies"] or list(manifest["dependencies"]) != ["puppeteer-core"]:
    fail("cli/package.json must declare puppeteer-core as its only dependency")
supported_version = manifest["dependencies"]["puppeteer-core"]
if not re.fullmatch(r"\d+\.\d+\.\d+", supported_version):
    fail(f"cli/package.json must pin an exact puppeteer-core version, not {supported_version!r}")
if not re.fullmatch(r">=\d+\.\d+\.\d+", manifest.get("engines", {}).get("node", "")):
    fail("cli/package.json must set engines.node as >=MAJOR.MINOR.PATCH for the wrapper to read")
locked_version = lock.get("packages", {}).get("node_modules/puppeteer-core", {}).get("version")
if locked_version != supported_version:
    fail(f"cli/package-lock.json locks puppeteer-core {locked_version}, not {supported_version}")

for path in repo_root.rglob("*"):
    if not path.is_file():
        continue
    relative = path.relative_to(repo_root)
    if ".git" in relative.parts or "node_modules" in relative.parts:
        continue
    content = path.read_text(encoding="utf-8")
    if macos_home_prefix in content or linux_home_prefix in content:
        fail(f"machine-specific home path found in {relative}")
    if "\u2013" in content or "\u2014" in content:
        fail(f"forbidden Unicode dash found in {relative}")
    if (
        supported_version in content
        and relative.parts[0] != "docs"
        and path.parent != cli_manifest_file.parent
    ):
        fail(f"{relative} spells the Puppeteer version; read it from cli/package-lock.json instead")

for path in (skill_dir / "scripts").glob("*"):
    content = path.read_text(encoding="utf-8")
    if re.search(r"\b(?:puppeteer|browser)\.launch\s*\(|browser\.close\s*\(", content):
        fail(f"browser launch or shutdown found in {path.name}")
    if "PLAYWRIGHT" in content or "Keychain" in content or "pbpaste" in content:
        fail(f"obsolete extension runtime found in {path.name}")

print("Agent Skill validation passed.")
