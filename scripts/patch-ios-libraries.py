#!/usr/bin/env python3
"""
Binary-patch SimpleX string literals in iOS static libraries (.a files).

This replaces user-visible SimpleX branding strings with Inqalaab equivalents.
Strings are replaced with same-length alternatives using space padding.

SAFE to patch (user-visible text, not protocol-level):
- "SimpleX Chat Ltd" -> "Inqalaab App   " (company name in legal text)
- "SimpleX Chat" -> "Inqalaab App" (product name)
- "SIMPLEX CHAT LTD" -> "INQALAAB APP   " (caps legal text)
- "SIMPLEX PARTIES" -> "INQALAAB USERS " (caps legal text)
- "SIMPLEX APPLICATIONS" -> "INQALAAB APPLICATIONS" (too long, skip)
- Server URIs: .simplex.im -> .inqlb.app (5 char domain)
- Server URIs: .simplexonflux.com -> padded replacement
- Email: chat@simplex.chat -> chat@inqalaab.chat (same length!)
- GitHub: simplex-chat/simplex-chat -> TheHealer28/Inqalaab (needs padding)
- DB prefix: simplex_v1 -> inqalb_v1 (shorter, null pad)

NOT patched (protocol-level / Codable):
- "simplexLink", "simplexLinks", "simplexUri" (JSON field names)
- "simplexmqCommit", "simplexmqVersion" (JSON field names)
- Haskell type tags ('SimplexLink, 'SIMPLEX, etc.)
- simplex:// URI scheme (protocol)
"""

import os
import sys
import shutil

def pad_replace(old: bytes, new: bytes) -> bytes:
    """Pad new string with spaces to match old string length."""
    if len(new) > len(old):
        raise ValueError(f"Replacement '{new}' is longer than original '{old}'")
    return new + b' ' * (len(old) - len(new))

# Replacements: (old_bytes, new_bytes)
# All replacements must be EXACT same length
REPLACEMENTS = [
    # Company name in legal text (17 chars)
    (b"SimpleX Chat Ltd", pad_replace(b"SimpleX Chat Ltd", b"Inqalaab App")),
    (b"SIMPLEX CHAT LTD", pad_replace(b"SIMPLEX CHAT LTD", b"INQALAAB APP")),

    # Product name variants - be careful not to match substrings of above
    # These are applied AFTER the "Ltd" replacements above
    # "SimpleX Chat Applications" (25 chars)
    (b"SimpleX Chat Applications", pad_replace(b"SimpleX Chat Applications", b"Inqalaab Applications")),
    (b"SimpleX Chat client", pad_replace(b"SimpleX Chat client", b"Inqalaab client")),
    (b"SimpleX Chat is", pad_replace(b"SimpleX Chat is", b"Inqalaab is")),
    (b"SimpleX Chat code", pad_replace(b"SimpleX Chat code", b"Inqalaab code")),
    (b"SimpleX Chat Software", pad_replace(b"SimpleX Chat Software", b"Inqalaab Software")),

    # Caps variants in disclaimers
    (b"SIMPLEX PARTIES", pad_replace(b"SIMPLEX PARTIES", b"INQALAAB USERS")),
    (b"SIMPLEX APPLICATIONS", pad_replace(b"SIMPLEX APPLICATIONS", b"INQALAAB APPS")),
    (b"USE SIMPLEX", pad_replace(b"USE SIMPLEX", b"USE INQALB")),

    # Title
    (b"# SimpleX Chat Operators Privacy Policy",
     pad_replace(b"# SimpleX Chat Operators Privacy Policy", b"# Inqalaab Operators Privacy Policy")),

    # SimpleX network references
    (b"SimpleX network", pad_replace(b"SimpleX network", b"Inqalb network")),
    (b"SimpleX Applications", pad_replace(b"SimpleX Applications", b"Inqalb Applications")),

    # Email (exact same length! 17 chars each)
    (b"chat@simplex.chat", b"chat@inqalaab.app"),

    # GitHub URLs
    (b"github.com/simplex-chat/simplex-chat", pad_replace(b"github.com/simplex-chat/simplex-chat", b"github.com/TheHealer28/Inqalaab")),
    (b"github.com/simplex-chat/simplexmq", pad_replace(b"github.com/simplex-chat/simplexmq", b"github.com/TheHealer28/Inqalaab")),

    # Install script URL
    (b"raw.githubusercontent.com/simplex-chat/simplex-chat/master/install.sh",
     pad_replace(b"raw.githubusercontent.com/simplex-chat/simplex-chat/master/install.sh",
                 b"github.com/TheHealer28/Inqalaab")),

    # SimpleX directory section header
    (b"#### SimpleX Directory", pad_replace(b"#### SimpleX Directory", b"#### App Directory")),

    # Contact link in privacy policy (simplex.chat/contact# -> inqalaab.chat/contact)
    (b"simplex.chat/contact#", pad_replace(b"simplex.chat/contact#", b"inqalaab.chat/link#")),

    # Server domains in XFTP URIs - replace domain parts
    # .simplex.im, -> .inqlb.im,  (keeping comma for URI parsing)
    (b".simplex.im,", pad_replace(b".simplex.im,", b".inqlb.app,")),
    (b".simplex.im/", pad_replace(b".simplex.im/", b".inqlb.app/")),

    # simplexonflux.com (16 chars) -> inqalaab.app (12 chars + pad)
    (b".simplexonflux.com,", pad_replace(b".simplexonflux.com,", b".inqalaab.app,")),
    (b".simplexonflux.com/", pad_replace(b".simplexonflux.com/", b".inqalaab.app/")),
    (b".simplexonflux.com", pad_replace(b".simplexonflux.com", b".inqalaab.app")),

    # SQL query with simplexonflux
    (b'%.simplexonflux.com,%', pad_replace(b'%.simplexonflux.com,%', b'%.inqalaab.app,%')),

    # Agent config paths
    (b"/etc/opt/simplex-agent/", pad_replace(b"/etc/opt/simplex-agent/", b"/etc/opt/inqalb-agent/")),

    # DB file prefix
    (b"simplex_v1_files", pad_replace(b"simplex_v1_files", b"inqalb_v1_files")),
    (b"simplex_v1_agent", pad_replace(b"simplex_v1_agent", b"inqalb_v1_agent")),
    (b"simplex_v1_xftp", pad_replace(b"simplex_v1_xftp", b"inqalb_v1_xftp")),
    (b"simplex_v1_chat.db", pad_replace(b"simplex_v1_chat.db", b"inqalb_v1_chat.db")),
    (b"simplex_v1_assets", pad_replace(b"simplex_v1_assets", b"inqalb_v1_assets")),

    # Privacy policy text: more "SimpleX Chat" variants
    (b"SimpleX Chat (also referred to as SimpleX)",
     pad_replace(b"SimpleX Chat (also referred to as SimpleX)", b"Inqalaab")),
    (b"SimpleX Chat network design",
     pad_replace(b"SimpleX Chat network design", b"Inqalaab network design")),
    (b"use SimpleX Chat applications",
     pad_replace(b"use SimpleX Chat applications", b"use Inqalaab applications")),
    (b"SimpleX Chat applications",
     pad_replace(b"SimpleX Chat applications", b"Inqalaab applications")),
    (b"SimpleX Chat software applications",
     pad_replace(b"SimpleX Chat software applications", b"Inqalaab software applications")),
    (b"SimpleX Chat software",
     pad_replace(b"SimpleX Chat software", b"Inqalaab software")),
    (b"SimpleX Chat apps",
     pad_replace(b"SimpleX Chat apps", b"Inqalaab apps")),
    (b"SimpleX Chat source code",
     pad_replace(b"SimpleX Chat source code", b"Inqalaab source code")),
    (b"SimpleX Chat app",
     pad_replace(b"SimpleX Chat app", b"Inqalaab app")),
    (b"SimpleX Chat v",
     pad_replace(b"SimpleX Chat v", b"Inqalaab v")),
    # Standalone "SimpleX Chat" (12 chars) — must come AFTER all longer variants above
    (b"SimpleX Chat\n",
     pad_replace(b"SimpleX Chat\n", b"Inqalaab\n")),

    # Privacy policy: more standalone SimpleX references
    (b"SimpleX software",
     pad_replace(b"SimpleX software", b"Inqalb software")),
    (b"SimpleX messaging protocol",
     pad_replace(b"SimpleX messaging protocol", b"Inqalb messaging protocol")),
    (b"SimpleX relay servers",
     pad_replace(b"SimpleX relay servers", b"Inqalb relay servers")),
    (b"SimpleX protocols",
     pad_replace(b"SimpleX protocols", b"Inqalb protocols")),
    (b"SimpleX iOS app",
     pad_replace(b"SimpleX iOS app", b"Inqalb iOS app")),
    (b"SimpleX client apps",
     pad_replace(b"SimpleX client apps", b"Inqalb client apps")),
    (b"SimpleX cryptography",
     pad_replace(b"SimpleX cryptography", b"Inqalb cryptography")),

    # Preset contacts (used in PRESET_CONTACTS_TO_DELETE but also in binary)
    (b"Ask SimpleX Team",
     pad_replace(b"Ask SimpleX Team", b"Ask Inqalb Team")),
    (b"SimpleX Status",
     pad_replace(b"SimpleX Status", b"Inqalb Status")),
    (b"Send questions about SimpleX",
     pad_replace(b"Send questions about SimpleX", b"Send questions about Inqalb")),

    # simplex.chat domain in privacy policy (not in simplex:// URIs)
    (b"simplex.chat/blog/",
     pad_replace(b"simplex.chat/blog/", b"inqalaab.app/blog/")),
    (b"simplex.chat/docs/",
     pad_replace(b"simplex.chat/docs/", b"inqalaab.app/docs/")),
    (b"domain name `simplex.chat`",
     pad_replace(b"domain name `simplex.chat`", b"domain name `inqalb.app` ")),

    # SMP server hostnames (in privacy policy contact URIs)
    (b"smp4.simplex.im",
     pad_replace(b"smp4.simplex.im", b"smp.inqlb.app ")),
    (b"smp5.simplex.im",
     pad_replace(b"smp5.simplex.im", b"smp.inqlb.app ")),
    (b"smp6.simplex.im",
     pad_replace(b"smp6.simplex.im", b"smp.inqlb.app ")),
    (b"smp8.simplex.im",
     pad_replace(b"smp8.simplex.im", b"smp.inqlb.app ")),
    (b"smp9.simplex.im",
     pad_replace(b"smp9.simplex.im", b"smp.inqlb.app ")),
    (b"smp10.simplex.im",
     pad_replace(b"smp10.simplex.im", b"smp.inqlb.app  ")),
    (b"smp.simplex.im",
     pad_replace(b"smp.simplex.im", b"smp.inqlb.app")),

    # NTF SQL query
    (b"ntf2.simplex.im",
     pad_replace(b"ntf2.simplex.im", b"ntf.inqlb.app ")),

    # simplexonflux standalone (last resort catch)
    (b"simplexonflux.com",
     pad_replace(b"simplexonflux.com", b"inqalaab.app ")),

    # simplex.im standalone (after all smpX.simplex.im are replaced)
    (b"simplex.im",
     pad_replace(b"simplex.im", b"inqlb.app ")),

    # SimpleX Directory in privacy policy
    (b"SimpleX Directory",
     pad_replace(b"SimpleX Directory", b"App Directory")),

    # Blog URL references in privacy policy
    (b"/blog/20220404-simplex-chat-instant-notifications.md#our-ios-approach-has-one-trade-off",
     pad_replace(b"/blog/20220404-simplex-chat-instant-notifications.md#our-ios-approach-has-one-trade-off",
                 b"the Inqalaab documentation")),
    (b"/blog/20221108-simplex-chat-v4.2-security-audit-new-website.md",
     pad_replace(b"/blog/20221108-simplex-chat-v4.2-security-audit-new-website.md",
                 b"the Inqalaab documentation")),
    (b"/blog/20241014-simplex-network-v6-1-security-review-better-calls-user-experience.md",
     pad_replace(b"/blog/20241014-simplex-network-v6-1-security-review-better-calls-user-experience.md",
                 b"the Inqalaab documentation")),

    # simplex.chat standalone (after contact# already matched)
    (b"simplex.chat",
     pad_replace(b"simplex.chat", b"inqalaab.app")),

    # Privacy policy: remaining "SimpleX" in longer paragraphs
    (b"SimpleX apps allow",
     pad_replace(b"SimpleX apps allow", b"Inqalb apps allow")),
    (b"SimpleX links",
     pad_replace(b"SimpleX links", b"Inqalb links")),

    # smp.simplex.im without number (standalone, after numbered ones)
    (b"smp.simplex.im",
     pad_replace(b"smp.simplex.im", b"smp.inqlb.app")),

    # Remaining "SimpleX" in privacy policy anchor/section references
    (b"SimpleX directory",
     pad_replace(b"SimpleX directory", b"App directory")),

    # Privacy text: built on top of SimpleX messaging
    (b"built on top of SimpleX messaging",
     pad_replace(b"built on top of SimpleX messaging", b"built on top of Inqalb messaging")),

    # Remaining simplex.chat in URLs (encoded)
    (b"simplex%2Echat",
     pad_replace(b"simplex%2Echat", b"inqalaab%2Eapp")),

    # Privacy policy: "SimpleX Chat\n" standalone at end of line
    (b"SimpleX Chat\r",
     pad_replace(b"SimpleX Chat\r", b"Inqalaab\r")),

    # Standalone "SimpleX Chat" followed by null byte (separate string literal)
    (b"SimpleX Chat\x00",
     pad_replace(b"SimpleX Chat\x00", b"Inqalaab\x00")),

    # "SimpleX links" in group preferences
    (b"SimpleX links",
     pad_replace(b"SimpleX links", b"Inqalb links")),

    # Privacy policy paragraph mentioning "simplex-directory" HTML anchor
    (b"#simplex-directory",
     pad_replace(b"#simplex-directory", b"#app-directory")),

    # NTF SQL WHERE clause
    (b"WHERE ntf_host = 'ntf2.simplex.im'",
     pad_replace(b"WHERE ntf_host = 'ntf2.simplex.im'", b"WHERE ntf_host = 'ntf.inqlb.app' ")),
]

def patch_file(filepath: str, dry_run: bool = False) -> dict:
    """Patch a single .a file. Returns dict of replacement counts."""
    with open(filepath, 'rb') as f:
        data = f.read()

    original_size = len(data)
    counts = {}

    for old, new in REPLACEMENTS:
        assert len(old) == len(new), f"Length mismatch: {old!r} ({len(old)}) vs {new!r} ({len(new)})"
        count = data.count(old)
        if count > 0:
            data = data.replace(old, new)
            counts[old.decode('utf-8', errors='replace')] = count

    assert len(data) == original_size, "File size changed!"

    if not dry_run and counts:
        # Backup
        backup = filepath + '.bak2'
        if not os.path.exists(backup):
            shutil.copy2(filepath, backup)
            print(f"  Backup: {backup}")

        with open(filepath, 'wb') as f:
            f.write(data)

    return counts

def main():
    dry_run = '--dry-run' in sys.argv

    lib_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           'apps/ios/Libraries/ios')

    a_files = [f for f in os.listdir(lib_dir) if f.endswith('.a') and not f.endswith('.bak') and not f.endswith('.bak2')]

    if not a_files:
        print("No .a files found!")
        sys.exit(1)

    mode = "DRY RUN" if dry_run else "PATCHING"
    print(f"=== {mode} iOS Static Libraries ===\n")

    total_replacements = 0

    for filename in sorted(a_files):
        filepath = os.path.join(lib_dir, filename)
        print(f"Processing: {filename}")
        counts = patch_file(filepath, dry_run)

        if counts:
            for pattern, count in sorted(counts.items(), key=lambda x: -x[1]):
                print(f"  {count:3d}x  {pattern[:60]}")
                total_replacements += count
        else:
            print("  No matches found")
        print()

    print(f"Total replacements: {total_replacements}")
    if dry_run:
        print("\nRe-run without --dry-run to apply changes.")

if __name__ == '__main__':
    main()
