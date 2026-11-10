# Nova Context demo

This directory is a new, independent macOS demo requested by the workspace owner.
It reuses the upstream MiaoYanCore package for decoding and frontmatter; upstream
app targets, branding, signing, preferences and installed MiaoYan must stay untouched.
Build with `swift build`
and test with `swift test` here. Package with `bash scripts/package.sh`.

Keep IO off the main actor. Never log user file contents. Never send project data
over the network. Environment values are always masked. No shell execution of
project instructions. Preserve conversion source documents; conversion exports are new files in a
user-selected destination. The owner explicitly authorized Markdown and UTF-8 text/code
editing: save only after an explicit save action, preserve unredacted source text,
protect unsaved changes and reject external-write conflicts. Retain upstream license notices.

The local credential vault is explicitly authorized. Store Token/password values only
in Keychain items owned by this app, with synchronization disabled. Metadata, project
tags and exported environment descriptions must never include those secret values.
SSH mode references a key path and never copies or reads private key contents. Reveal
or copy credentials only after an explicit user action. Never broaden Keychain access
groups, inject credentials into another process, or transmit them as part of QA.
