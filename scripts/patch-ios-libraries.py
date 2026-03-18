#!/usr/bin/env python3
"""
Binary-patch SimpleX string literals in iOS static libraries (.a files).

Deep de-SimpleX patching for Apple 4.3(a) compliance. Covers:
1. Z-encoded GHC symbol names (107K+ occurrences in symbol tables)
2. GHC package IDs in data sections (~3300 occurrences)
3. Haskell module paths (GHC info tables, error messages)
4. Source file paths (src/Simplex/...)
5. Cabal Paths module strings (simplex_chat_*dir, simplexmq_*dir)
6. Nix store paths
7. Server URIs, domains, email, GitHub URLs
8. DB file prefixes, agent config paths
9. User-visible branding text

All replacements are EXACT same byte length to preserve binary structure.
Symbol table entries stay valid because only content bytes change, not offsets.

NOT patched (protocol-critical — would break runtime):
- "simplexLink", "simplexLinks", "simplexUri" (JSON Codable field names)
- simplex:// URI scheme (protocol identifier)
- Haskell type constructors used in JSON serialization
- Bare "simplex" catch-all (corrupts compiled parser code)
- Any pattern that changes wire-format or database-stored values

All replacements are EXACT same byte length to preserve binary structure.
Symbol table entries stay valid because only content bytes change, not offsets.
"""

import os
import sys
import shutil

def pad_replace(old: bytes, new: bytes) -> bytes:
    """Pad new string with spaces to match old string length."""
    if len(new) > len(old):
        raise ValueError(f"Replacement '{new}' is longer than original '{old}'")
    return new + b' ' * (len(old) - len(new))

def null_pad(old: bytes, new: bytes) -> bytes:
    """Pad new string with null bytes to match old string length."""
    if len(new) > len(old):
        raise ValueError(f"Replacement '{new}' is longer than original '{old}'")
    return new + b'\x00' * (len(old) - len(new))

# Replacements: (old_bytes, new_bytes)
# All replacements must be EXACT same length
# ORDER MATTERS: longer/more-specific patterns MUST come before shorter ones
REPLACEMENTS = [
    # ===================================================================
    # PHASE 0: Z-ENCODED GHC SYMBOL NAMES (107K+ occurrences)
    # These are in the Mach-O symbol table (__symtab section).
    # GHC z-encodes package names: simplex-chat -> simplexzmchat,
    # Simplex.Chat -> SimplexziChat, etc.
    # "simplex" (7) -> "inqalbi" (7) = same length, safe replacement.
    # ===================================================================

    # Z-encoded package ID prefixes (must come before module names)
    # simplex-chat package (GHC 9.6.3 Hydra build): _simplexzmchatzm6zi4zi10zi0zmXJiehN1njt80oY4lUUScm
    # 52 chars each — exact same length
    (b"_simplexzmchatzm6zi4zi10zi0zmXJiehN1njt80oY4lUUScm",
     b"_inqalbizmchatzm6zi4zi10zi0zmXJiehN1njt80oY4lUUScm"),
    # simplex-chat package (GHC 9.6.6 rebuild): _simplexzmchatzm6zi4zi10zi0zm78vNPAZZj4Es5TqTDc5X55m
    (b"_simplexzmchatzm6zi4zi10zi0zm78vNPAZZj4Es5TqTDc5X55m",
     b"_inqalbizmchatzm6zi4zi10zi0zm78vNPAZZj4Es5TqTDc5X55m"),

    # simplexmq package (GHC 9.6.3 Hydra build): _simplexmqzm6zi4zi8zi0zmB6wU3LNNSMG8WHdL0SwVWA
    # 48 chars each
    (b"_simplexmqzm6zi4zi8zi0zmB6wU3LNNSMG8WHdL0SwVWA",
     b"_inqalbimqzm6zi4zi8zi0zmB6wU3LNNSMG8WHdL0SwVWA"),
    # simplexmq package (GHC 9.6.6 rebuild): _simplexmqzm6zi4zi8zi0zmEs4V04fCS84CLqT0nnHeL5
    (b"_simplexmqzm6zi4zi8zi0zmEs4V04fCS84CLqT0nnHeL5",
     b"_inqalbimqzm6zi4zi8zi0zmEs4V04fCS84CLqT0nnHeL5"),

    # Z-encoded module names inside symbols (after package prefix)
    # These appear as e.g. _<pkg>_SimplexziChatziController_functionName
    # Must go longest-first to avoid partial matches
    # SimplexziRemoteControl (22 chars each)
    (b"SimplexziRemoteControl", b"InqalbiziRemoteControl"),
    # SimplexziFileTransfer (21 chars each)
    (b"SimplexziFileTransfer", b"InqalbiziFileTransfer"),
    # SimplexziMessaging (18 chars each)
    (b"SimplexziMessaging", b"InqalbiziMessaging"),
    # SimplexziChat (13 chars each)
    (b"SimplexziChat", b"InqalbiziChat"),

    # Z-encoded Cabal Paths module names in symbols
    # Pathszusimplexzmchat (20 chars) — z-encoding of Paths_simplex_chat
    (b"Pathszusimplexzmchat", b"Pathszuinqalbizmchat"),
    # Pathszusimplexzuchat (20 chars) — alternate z-encoding (underscore = zu)
    (b"Pathszusimplexzuchat", b"Pathszuinqalbizuchat"),
    # Pathszusimplexmq (16 chars)
    (b"Pathszusimplexmq", b"Pathszuinqlbismq"),

    # GHC wrapper symbols with z-encoded names
    # These have format: _ghczuwrapperZC<N>ZC<pkg>ZC<module>ZC<name>
    (b"ZCsimplexmqzm", b"ZCinqalbimqzm"),
    (b"ZCsimplexzmchatzm", b"ZCinqalbizmchatzm"),

    # ===================================================================
    # PHASE 0b: DOUBLE-Z ENCODED GHC SYMBOLS (~200 occurrences)
    # GHC uses double-Z encoding (ZZ) in FFI export stubs and stable ptrs.
    # zzm = double-z of zm (encodes -), zzi = double-z of zi (encodes .)
    # ===================================================================

    # Double-z package ID (GHC 9.6.3): simplexzzmchatzzm -> inqalbizzmchatzzm (17 chars each)
    (b"simplexzzmchatzzm", b"inqalbizzmchatzzm"),
    # Double-z package (GHC 9.6.3): simplexmqzzm -> inqalbimqzzm (12 chars each)
    (b"simplexmqzzm", b"inqalbimqzzm"),
    # Double-z module names: Simplexzzi -> Inqalbizzi
    (b"SimplexzziRemoteControl", b"InqalbizziRemoteControl"),
    (b"SimplexzziFileTransfer", b"InqalbizziFileTransfer"),
    (b"SimplexzziMessaging", b"InqalbizziMessaging"),
    (b"SimplexzziChat", b"InqalbizziChat"),
    # Double-z in ZZC separator
    (b"ZZCsimplexzzmchatzzm", b"ZZCinqalbizzmchatzzm"),
    (b"ZZCSimplexzzi", b"ZZCInqalbizzi"),
    (b"ZZCsimplexmqzzm", b"ZZCinqalbimqzzm"),

    # ===================================================================
    # PHASE 0e: REMOVED — Protocol-critical JSON/type names
    # These were causing runtime crashes (endOfInput parser errors).
    # Wire-format names (simplexLinks, simplexLink, simplexUri, SIMPLEX,
    # simplex:/ URI scheme, type constructors) must stay as-is because:
    # 1. SMP servers emit these names in protocol messages
    # 2. Stored database rows contain these names
    # 3. Haskell parser logic depends on these exact byte sequences
    # The Swift Codable layer must match what the Haskell binary emits.
    # ===================================================================

    # ===================================================================
    # PHASE 0c: CAMELCASE FUNCTION NAMES IN SYMBOLS (~150 occurrences)
    # Internal Haskell function names containing SimpleX/simplex.
    # NOT protocol-critical — these are compiled function names, not
    # JSON keys. JSON field names are separate data strings.
    # ===================================================================

    # Function names: operatorSimpleXChat (18 chars each, X->I keeps length)
    (b"operatorSimpleXChat", b"operatorInqalbiChat"),
    # simplexChatSMPServers -> inqalbiChatSMPServers (same: simplex=7, inqalbi=7)
    (b"simplexChatSMPServers", b"inqalbiChatSMPServers"),
    # simplexTeamContactProfile -> inqalbiTeamContactProfile
    (b"simplexTeamContactProfile", b"inqalbiTeamContactProfile"),
    # simplexStatusContactProfile -> inqalbiStatusContactProfile
    (b"simplexStatusContactProfile", b"inqalbiStatusContactProfile"),
    # simplexChat (standalone, as in service scheme) — 11 chars
    # Must come AFTER simplexChatSMPServers to avoid partial match
    (b"simplexChat\x00", b"inqalbiChat\x00"),
    # simplexConnReqUri -> inqalbiConnReqUri
    (b"simplexConnReqUri", b"inqalbiConnReqUri"),
    # simplexShortLink -> inqalbiShortLink
    (b"simplexShortLink", b"inqalbiShortLink"),
    # simplexMQVersion -> inqalbiMQVersion
    (b"simplexMQVersion", b"inqalbiMQVersion"),
    # isSimplexLink -> isInqalbiLink
    (b"isSimplexLink", b"isInqalbiLink"),
    # prohibitedSimplexLinks -> prohibitedInqalbiLinks
    (b"prohibitedSimplexLinks", b"prohibitedInqalbiLinks"),
    # disabledSimplexChatSMPServers -> disabledInqalbiChatSMPServers
    (b"disabledSimplexChatSMPServers", b"disabledInqalbiChatSMPServers"),
    # enabledSimplexChatSMPServers -> enabledInqalbiChatSMPServers
    (b"enabledSimplexChatSMPServers", b"enabledInqalbiChatSMPServers"),

    # ===================================================================
    # PHASE 0d: CRYPTO TYPE NAMES (~14 occurrences)
    # Internal Haskell data constructors for double ratchet crypto.
    # Used in Show instances and error messages, NOT in JSON serialization.
    # SimpleX (7) -> Inqalbi (7) = same length.
    # ===================================================================
    (b"SimpleXX3DH", b"InqalbiX3DH"),
    (b"SimpleXSbChainInit", b"InqalbiSbChainInit"),
    (b"SimpleXSbChain\x00", b"InqalbiSbChain\x00"),
    (b"SimpleXRootRatchet", b"InqalbiRootRatchet"),
    (b"SimpleXInvLink", b"InqalbiInvLink"),
    (b"SimpleXContactLink", b"InqalbiContactLink"),
    (b"SimpleXChainRatchet", b"InqalbiChainRatchet"),

    # ===================================================================
    # PHASE 1: GHC Package IDs in data sections (~3300 occurrences)
    # These are Cabal package identifiers in GHC info tables.
    # ===================================================================
    # simplex-chat package IDs
    (b"simplex-chat-6.4.10.0-XJiehN1njt80oY4lUUScm",
     b"inqalb--app--6.4.10.0-XJiehN1njt80oY4lUUScm"),
    (b"simplex-chat-6.4.10.0-78vNPAZj4Es5TqTDc5X55m",
     b"inqalb--app--6.4.10.0-78vNPAZj4Es5TqTDc5X55m"),
    # simplexmq package IDs
    (b"simplexmq-6.4.8.0-B6wU3LNNSMG8WHdL0SwVWA",
     b"inqlb-msg-6.4.8.0-B6wU3LNNSMG8WHdL0SwVWA"),
    (b"simplexmq-6.4.8.0-Es4V04fCS84CLqT0nnHeL5",
     b"inqlb-msg-6.4.8.0-Es4V04fCS84CLqT0nnHeL5"),

    # ===================================================================
    # PHASE 2: Haskell module paths (GHC info tables, error messages)
    # Order: longest module prefix first to avoid partial matches.
    # ===================================================================
    (b"Simplex.RemoteControl.", pad_replace(b"Simplex.RemoteControl.", b"Inqalbi.RemoteControl.")),
    (b"Simplex.FileTransfer.", pad_replace(b"Simplex.FileTransfer.", b"Inqalbi.FileTransfer.")),
    (b"Simplex.Messaging.", pad_replace(b"Simplex.Messaging.", b"Inqalbi.Messaging.")),
    (b"Simplex.Chat.", pad_replace(b"Simplex.Chat.", b"Inqalbi.Chat.")),
    # Standalone "Simplex.Chat" without trailing dot (e.g. in package:module format)
    (b"Simplex.Chat\x00", b"Inqalbi.Chat\x00"),

    # ===================================================================
    # PHASE 3: Source file paths in GHC debug info
    # ===================================================================
    (b"src/Simplex/", pad_replace(b"src/Simplex/", b"src/Inqalbi/")),

    # ===================================================================
    # PHASE 4: Cabal Paths module strings
    # ===================================================================
    (b"Paths_simplex_chat", pad_replace(b"Paths_simplex_chat", b"Paths_inqalb_chat")),
    (b"Paths_simplexmq", pad_replace(b"Paths_simplexmq", b"Paths_inqlbsmq")),
    (b"simplex_chat_sysconfdir", pad_replace(b"simplex_chat_sysconfdir", b"inqlb_chat_sysconfdir")),
    (b"simplex_chat_libexecdir", pad_replace(b"simplex_chat_libexecdir", b"inqlb_chat_libexecdir")),
    (b"simplex_chat_dynlibdir", pad_replace(b"simplex_chat_dynlibdir", b"inqlb_chat_dynlibdir")),
    (b"simplex_chat_datadir", pad_replace(b"simplex_chat_datadir", b"inqlb_chat_datadir")),
    (b"simplex_chat_libdir", pad_replace(b"simplex_chat_libdir", b"inqlb_chat_libdir")),
    (b"simplex_chat_bindir", pad_replace(b"simplex_chat_bindir", b"inqlb_chat_bindir")),
    (b"simplexmq_sysconfdir", pad_replace(b"simplexmq_sysconfdir", b"inqlbmq_sysconfdir")),
    (b"simplexmq_libexecdir", pad_replace(b"simplexmq_libexecdir", b"inqlbmq_libexecdir")),
    (b"simplexmq_dynlibdir", pad_replace(b"simplexmq_dynlibdir", b"inqlbmq_dynlibdir")),
    (b"simplexmq_datadir", pad_replace(b"simplexmq_datadir", b"inqlbmq_datadir")),
    (b"simplexmq_libdir", pad_replace(b"simplexmq_libdir", b"inqlbmq_libdir")),
    (b"simplexmq_bindir", pad_replace(b"simplexmq_bindir", b"inqlbmq_bindir")),

    # ===================================================================
    # PHASE 4b: Nix store paths
    # These are build-time paths baked into the library. Not used at runtime.
    # ===================================================================
    # simplex-chat data store path (GHC 9.6.3 Hydra build)
    (b"/nix/store/wz30zfbcfmv4c4jpmmdl65x7r13kv5mb-simplex-chat-lib-simplex-chat-6.4.10.0-data/share/ghc-9.6.3/aarch64-osx-ghc-9.6.3/",
     pad_replace(b"/nix/store/wz30zfbcfmv4c4jpmmdl65x7r13kv5mb-simplex-chat-lib-simplex-chat-6.4.10.0-data/share/ghc-9.6.3/aarch64-osx-ghc-9.6.3/",
                 b"/nix/store/inqalbi-app-data/share/ghc-9.6.3/aarch64-osx-ghc-9.6.3/")),
    # simplexmq lib paths (GHC 9.6.3 Hydra build)
    (b"/nix/store/n1rzhv1c2239ilay2mpgs8v9nllrhpfg-simplexmq-lib-simplexmq-6.4.8.0/libexec/aarch64-osx-ghc-9.6.3/simplexmq-6.4.8.0",
     pad_replace(b"/nix/store/n1rzhv1c2239ilay2mpgs8v9nllrhpfg-simplexmq-lib-simplexmq-6.4.8.0/libexec/aarch64-osx-ghc-9.6.3/simplexmq-6.4.8.0",
                 b"/nix/store/inqalbi-msg-lib/libexec/aarch64-osx-ghc-9.6.3/inqlb-msg-6.4.8.0")),
    (b"/nix/store/n1rzhv1c2239ilay2mpgs8v9nllrhpfg-simplexmq-lib-simplexmq-6.4.8.0/lib/aarch64-osx-ghc-9.6.3/",
     pad_replace(b"/nix/store/n1rzhv1c2239ilay2mpgs8v9nllrhpfg-simplexmq-lib-simplexmq-6.4.8.0/lib/aarch64-osx-ghc-9.6.3/",
                 b"/nix/store/inqalbi-msg-lib/lib/aarch64-osx-ghc-9.6.3/")),
    (b"/nix/store/n1rzhv1c2239ilay2mpgs8v9nllrhpfg-simplexmq-lib-simplexmq-6.4.8.0/etc",
     pad_replace(b"/nix/store/n1rzhv1c2239ilay2mpgs8v9nllrhpfg-simplexmq-lib-simplexmq-6.4.8.0/etc",
                 b"/nix/store/inqalbi-msg-lib/etc")),
    (b"/nix/store/n1rzhv1c2239ilay2mpgs8v9nllrhpfg-simplexmq-lib-simplexmq-6.4.8.0/bin",
     pad_replace(b"/nix/store/n1rzhv1c2239ilay2mpgs8v9nllrhpfg-simplexmq-lib-simplexmq-6.4.8.0/bin",
                 b"/nix/store/inqalbi-msg-lib/bin")),
    # simplex-chat lib paths (GHC 9.6.3 Hydra build)
    (b"/nix/store/a9q5lvg8d79s3ss8rmb28vjq3gm91wd5-simplex-chat-lib-simplex-chat-6.4.10.0/libexec/aarch64-osx-ghc-9.6.3/simplex-chat-6.4.10.0",
     pad_replace(b"/nix/store/a9q5lvg8d79s3ss8rmb28vjq3gm91wd5-simplex-chat-lib-simplex-chat-6.4.10.0/libexec/aarch64-osx-ghc-9.6.3/simplex-chat-6.4.10.0",
                 b"/nix/store/inqalbi-app-lib/libexec/aarch64-osx-ghc-9.6.3/inqalb-app-6.4.10.0")),
    (b"/nix/store/a9q5lvg8d79s3ss8rmb28vjq3gm91wd5-simplex-chat-lib-simplex-chat-6.4.10.0/lib/aarch64-osx-ghc-9.6.3",
     pad_replace(b"/nix/store/a9q5lvg8d79s3ss8rmb28vjq3gm91wd5-simplex-chat-lib-simplex-chat-6.4.10.0/lib/aarch64-osx-ghc-9.6.3",
                 b"/nix/store/inqalbi-app-lib/lib/aarch64-osx-ghc-9.6.3")),
    (b"/nix/store/a9q5lvg8d79s3ss8rmb28vjq3gm91wd5-simplex-chat-lib-simplex-chat-6.4.10.0/etc",
     pad_replace(b"/nix/store/a9q5lvg8d79s3ss8rmb28vjq3gm91wd5-simplex-chat-lib-simplex-chat-6.4.10.0/etc",
                 b"/nix/store/inqalbi-app-lib/etc")),
    (b"/nix/store/a9q5lvg8d79s3ss8rmb28vjq3gm91wd5-simplex-chat-lib-simplex-chat-6.4.10.0/bin",
     pad_replace(b"/nix/store/a9q5lvg8d79s3ss8rmb28vjq3gm91wd5-simplex-chat-lib-simplex-chat-6.4.10.0/bin",
                 b"/nix/store/inqalbi-app-lib/bin")),
    # simplexmq data store path (GHC 9.6.3 Hydra build)
    (b"/nix/store/l1ki2gmrhdrv7lvyckswbwdfxj5gjjc0-simplexmq-lib-simplexmq-6.4.8.0-data/share/ghc-9.6.3/aarch64-osx-ghc-9.6.3/",
     pad_replace(b"/nix/store/l1ki2gmrhdrv7lvyckswbwdfxj5gjjc0-simplexmq-lib-simplexmq-6.4.8.0-data/share/ghc-9.6.3/aarch64-osx-ghc-9.6.3/",
                 b"/nix/store/inqalbi-msg-data/share/ghc-9.6.3/aarch64-osx-ghc-9.6.3/")),
    # Current GHC 9.6.6 rebuild paths still leaking package names in libexec metadata
    (b"/nix/store/v7yga26dvwzbpzyrrwzmipqglr7l3q0b-inqalbi-app-lib-inqalbi-app-  6.4.10.0/libexec/aarch64-osx-ghc-9.6.6/simplex-chat-6.4.10.0",
     pad_replace(b"/nix/store/v7yga26dvwzbpzyrrwzmipqglr7l3q0b-inqalbi-app-lib-inqalbi-app-  6.4.10.0/libexec/aarch64-osx-ghc-9.6.6/simplex-chat-6.4.10.0",
                 b"/nix/store/inqalbi-app-lib/libexec/aarch64-osx-ghc-9.6.6/inqalbi-app-6.4.10.0")),
    (b"/nix/store/5qfdc1wkw72hd26jblk2ly0ch5w36mi6-inqalbi-msg-lib-inqalbi-6.4.8.0/libexec/aarch64-osx-ghc-9.6.6/simplexmq-6.4.8.0",
     pad_replace(b"/nix/store/5qfdc1wkw72hd26jblk2ly0ch5w36mi6-inqalbi-msg-lib-inqalbi-6.4.8.0/libexec/aarch64-osx-ghc-9.6.6/simplexmq-6.4.8.0",
                 b"/nix/store/inqalbi-msg-lib/libexec/aarch64-osx-ghc-9.6.6/inqalbimq-6.4.8.0")),
    (b"/etc/opt/simplex-agent/", b"/etc/opt/inqalbi-agent/"),
    # Catch remaining /nix/store/.../lib path that wasn't caught by longer variant
    (b"-simplexmq-lib-simplexmq-",
     pad_replace(b"-simplexmq-lib-simplexmq-", b"-inqalbi-msg-lib-inqalbi-")),
    (b"-simplex-chat-lib-simplex-chat-",
     pad_replace(b"-simplex-chat-lib-simplex-chat-", b"-inqalbi-app-lib-inqalbi-app-")),
    # Cabal autogen paths
    (b"dist/build/autogen/Paths_simplex_chat.hs",
     pad_replace(b"dist/build/autogen/Paths_simplex_chat.hs", b"dist/build/autogen/Paths_inqalb_chat.hs")),
    (b"dist/build/autogen/Paths_simplexmq.hs",
     pad_replace(b"dist/build/autogen/Paths_simplexmq.hs", b"dist/build/autogen/Paths_inqlbsmq.hs")),

    # ===================================================================
    # PHASE 5: Protocol version strings
    # (Removed specific patterns — Phase 7 catch-all handles these
    # consistently: simplexmqVersion -> inqalbimqVersion, etc.)
    # ===================================================================

    # ===================================================================
    # PHASE 5b: Standalone data section strings containing "simplex-chat"
    # These appear as package references in GHC info tables
    # ===================================================================
    (b"simplex-chat.", pad_replace(b"simplex-chat.", b"inqalb-app.")),

    # ===================================================================
    # PHASE 6: REMOVED — User-visible branding text
    # All branding text patches (SimpleX Chat Ltd, simplex.chat domain,
    # privacy policy text, blog URLs, contact names, etc.) are REMOVED.
    # These modify the embedded operator conditions text whose hash is
    # validated at runtime. Changing any of it breaks SMP operator
    # acceptance and kills all SMP connections.
    # User-visible text is rebranded in the Swift UI layer instead.
    # ===================================================================

    # ===================================================================
    # PHASE 6b: Legacy relay/domain literals still leaking from bundled
    # dependency archives. The iOS app injects its own managed SMP/XFTP set,
    # so these old SimpleX host/domain names are replaced with same-length
    # Inqalaab placeholders to keep them out of the shipped framework.
    # ===================================================================
    (b"smp10.simplex.im", pad_replace(b"smp10.simplex.im", b"smp10.inqlb.chat")),
    (b"smp9.simplex.im", pad_replace(b"smp9.simplex.im", b"smp9.inqlb.chat")),
    (b"smp8.simplex.im", pad_replace(b"smp8.simplex.im", b"smp8.inqlb.chat")),
    (b"smp6.simplex.im", pad_replace(b"smp6.simplex.im", b"smp6.inqlb.chat")),
    (b"smp5.simplex.im", pad_replace(b"smp5.simplex.im", b"smp5.inqlb.chat")),
    (b"smp4.simplex.im", pad_replace(b"smp4.simplex.im", b"smp4.inqlb.chat")),
    (b"ntf2.simplex.im", pad_replace(b"ntf2.simplex.im", b"ntf2.inqlb.chat")),
    (b"simplex.chat", pad_replace(b"simplex.chat", b"inqalaab.app")),

    # NTF server URIs — replace with Inqalaab NTF server (null-padded)
    (b"ntf://CJ5o7X6fCxj2FFYRU2KuCo70y4jSqz7td2HYhLnXWbU=@ntf4.simplex.im,wtvuhdj26jwprmomnyfu5wfuq2hjkzfcc72u44vi6gdhrwxldt6xauad.onion",
     null_pad(b"ntf://CJ5o7X6fCxj2FFYRU2KuCo70y4jSqz7td2HYhLnXWbU=@ntf4.simplex.im,wtvuhdj26jwprmomnyfu5wfuq2hjkzfcc72u44vi6gdhrwxldt6xauad.onion",
              b"ntf://0000000000000000000000000000000000000000014=@ntf.example.org")),
    (b"ntf://KmpZNNXiVZJx_G2T7jRUmDFxWXM3OAnunz3uLT0tqAA=@ntf3.simplex.im,pxculznuryunjdvtvh6s6szmanyadumpbmvevgdpe4wk5c65unyt4yid.onion",
     null_pad(b"ntf://KmpZNNXiVZJx_G2T7jRUmDFxWXM3OAnunz3uLT0tqAA=@ntf3.simplex.im,pxculznuryunjdvtvh6s6szmanyadumpbmvevgdpe4wk5c65unyt4yid.onion",
              b"ntf://0000000000000000000000000000000000000000014=@ntf.example.org")),
]

# File renames: (old_name_pattern, new_name_pattern)
FILE_RENAMES = [
    ("libHSsimplex-chat-", "libHSinqalb-app-"),
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
        # Backup original
        backup = filepath + '.bak3'
        if not os.path.exists(backup):
            shutil.copy2(filepath, backup)
            print(f"  Backup: {backup}")

        current_mode = os.stat(filepath).st_mode
        os.chmod(filepath, current_mode | 0o200)
        with open(filepath, 'wb') as f:
            f.write(data)
        os.chmod(filepath, current_mode & ~0o222)

    return counts


def process_lib_dir(lib_dir, dry_run, restore):
    """Process all .a files in a single library directory."""
    if not os.path.isdir(lib_dir):
        print(f"  Directory not found: {lib_dir}, skipping")
        return 0

    if restore:
        for f in os.listdir(lib_dir):
            if f.endswith('.a.bak') and 'simplex' in f:
                orig_name = f[:-4]  # remove .bak
                src = os.path.join(lib_dir, f)
                dst = os.path.join(lib_dir, orig_name)
                shutil.copy2(src, dst)
                print(f"  Restored: {orig_name}")
                # Also remove any renamed versions
                for renamed in os.listdir(lib_dir):
                    if renamed.startswith('libHSinqalb') and renamed.endswith('.a') and not renamed.endswith('.bak') and not renamed.endswith('.bak2') and not renamed.endswith('.bak3'):
                        os.remove(os.path.join(lib_dir, renamed))
                        print(f"  Removed renamed: {renamed}")
        return 0

    a_files = [f for f in os.listdir(lib_dir)
               if f.endswith('.a')
               and not f.endswith('.bak')
               and not f.endswith('.bak2')
               and not f.endswith('.bak3')]

    total = 0
    for filename in sorted(a_files):
        filepath = os.path.join(lib_dir, filename)
        print(f"Processing: {filename}")
        counts = patch_file(filepath, dry_run)

        if counts:
            for pattern, count in sorted(counts.items(), key=lambda x: -x[1]):
                print(f"  {count:6d}x  {pattern[:70]}")
                total += count
        else:
            print("  No matches found")
        print()

    # Rename files
    if not dry_run:
        for filename in sorted(a_files):
            new_name = filename
            for old_pat, new_pat in FILE_RENAMES:
                new_name = new_name.replace(old_pat, new_pat)
            if new_name != filename:
                old_path = os.path.join(lib_dir, filename)
                new_path = os.path.join(lib_dir, new_name)
                os.rename(old_path, new_path)
                print(f"  Renamed: {filename} -> {new_name}")

    return total


def main():
    dry_run = '--dry-run' in sys.argv
    restore = '--restore' in sys.argv

    base_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            'apps/ios/Libraries')
    lib_dirs = [os.path.join(base_dir, d) for d in ('ios', 'sim')]

    if restore:
        print("=== RESTORING from .bak originals ===\n")
        for lib_dir in lib_dirs:
            print(f"--- {os.path.basename(lib_dir)}/ ---")
            process_lib_dir(lib_dir, dry_run, restore=True)
        print()

    mode = "DRY RUN" if dry_run else "PATCHING"
    print(f"=== {mode} iOS Static Libraries ===\n")

    total_replacements = 0
    for lib_dir in lib_dirs:
        print(f"--- {os.path.basename(lib_dir)}/ ---")
        total_replacements += process_lib_dir(lib_dir, dry_run, restore=False)

    print(f"\nTotal replacements: {total_replacements}")

    if dry_run:
        print("\nRe-run without --dry-run to apply changes.")


if __name__ == '__main__':
    main()
