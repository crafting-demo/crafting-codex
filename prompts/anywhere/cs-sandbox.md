---
description: Say which Crafting sandbox this thread is running in
---

Report the sandbox this conversation is running in, following the
`crafting-sandbox` skill's "Which Sandbox Am I In" section.

```bash
cat /run/sandbox/fs/metadata/sandbox.json
```

The `name` field is the answer. Do not use `$SANDBOX_NAME`: it is baked when
the sandbox is built, so a sandbox claimed from the router's warm pool reports
a stale or empty name.

Answer with the name in one short sentence. Add the template it came from
(`cat /run/sandbox/fs/metadata/template.json`) only if asked.

If that file does not exist, this is not running inside a Crafting sandbox --
say so, and use `cs sandbox list` if the user is looking for a sandbox by
name.
