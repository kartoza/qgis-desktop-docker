#!/usr/bin/env python3
"""Parse Grype CVE scan JSON output into a deduplicated markdown table."""
import json
import sys

SEVERITY_EMOJI = {
    "Critical": "🔴",
    "High": "🟠",
    "Medium": "🟡",
    "Low": "🔵",
    "Negligible": "⚪",
    "Unknown": "⚪",
}

SEVERITY_ORDER = {
    "Critical": 0,
    "High": 1,
    "Medium": 2,
    "Low": 3,
    "Negligible": 4,
    "Unknown": 5,
}

IMPACT_ASSESSMENT = """
> **Impact Assessment:** This container runs a QGIS desktop application
> accessible via KasmVNC over HTTP. It does not directly accept untrusted
> user input from the network beyond the VNC web interface. It does not run
> a database server or expose APIs. The primary threat surface is the
> KasmVNC web interface (port 8443) which has no authentication enabled by
> default. For production use, place behind a reverse proxy with
> authentication. CVEs in system libraries (glibc, openssl, etc.) have
> limited exploitability in this context as the container is typically
> run locally for desktop GIS work.
"""


def main():
    if len(sys.argv) < 2:
        print("Usage: cve_table.py <grype-json-file>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        data = json.load(f)

    matches = data.get("matches", [])

    if not matches:
        print("**No known CVEs detected in this image.**\n")
        print(IMPACT_ASSESSMENT)
        return

    # Deduplicate by CVE ID + package name + version
    seen = set()
    rows = []
    for match in matches:
        vuln = match.get("vulnerability", {})
        cve_id = vuln.get("id", "unknown")
        severity = vuln.get("severity", "Unknown")

        artifact = match.get("artifact", {})
        pkg_name = artifact.get("name", "unknown")
        pkg_version = artifact.get("version", "unknown")

        dedup_key = f"{cve_id}:{pkg_name}:{pkg_version}"
        if dedup_key in seen:
            continue
        seen.add(dedup_key)

        description = vuln.get("description", "")[:120]
        if len(vuln.get("description", "")) > 120:
            description += "..."

        cvss_scores = vuln.get("cvss", [])
        cvss = "-"
        for score in cvss_scores:
            if "metrics" in score and "baseScore" in score["metrics"]:
                cvss = str(score["metrics"]["baseScore"])
                break

        fixed_in = "-"
        fix = vuln.get("fix", {})
        if fix and fix.get("versions"):
            fixed_in = ", ".join(fix["versions"])

        nvd_link = f"[{cve_id}](https://nvd.nist.gov/vuln/detail/{cve_id})"

        rows.append((
            SEVERITY_ORDER.get(severity, 5),
            cve_id,
            severity,
            cvss,
            nvd_link,
            pkg_name,
            pkg_version,
            fixed_in,
            description,
        ))

    rows.sort(key=lambda r: (r[0], r[1]))

    # Summary counts
    counts = {}
    for row in rows:
        sev = row[2]
        counts[sev] = counts.get(sev, 0) + 1

    summary_parts = []
    for sev in ["Critical", "High", "Medium", "Low", "Negligible"]:
        if sev in counts:
            emoji = SEVERITY_EMOJI.get(sev, "")
            summary_parts.append(f"{emoji} {counts[sev]} {sev}")

    print(f"**{len(rows)} unique CVEs found:** {', '.join(summary_parts)}\n")
    print("<details>")
    print(f"<summary>CVE Details ({len(rows)} vulnerabilities)</summary>\n")
    print("| Severity | CVSS | CVE | Package | Version | Fixed In | Description |")
    print("|----------|------|-----|---------|---------|----------|-------------|")
    for _, cve_id, severity, cvss, nvd_link, pkg_name, pkg_version, fixed_in, desc in rows:
        emoji = SEVERITY_EMOJI.get(severity, "")
        print(f"| {emoji} {severity} | {cvss} | {nvd_link} | {pkg_name} | {pkg_version} | {fixed_in} | {desc} |")
    print("\n</details>\n")
    print(IMPACT_ASSESSMENT)


if __name__ == "__main__":
    main()
