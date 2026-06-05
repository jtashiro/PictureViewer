# Copilot working rules for this repo

This codebase is AI-maintained. Editing discipline matters — past sessions have truncated files, deleted functions without creating destinations, and left the project non-buildable. The rules below are not suggestions.

## File-edit discipline

1. **Never replace a whole file unless you are creating a new file.** All edits to existing files must be diffs that touch only the changed regions. If your tool offers a "write entire file" mode, do not use it for existing files.

2. **Before editing any file, record its current line count.** Report it. After editing, report the new line count and the delta. If the delta is unexpectedly large (>50 lines for a single-function change), stop and ask before continuing.

3. **Never delete a function or type without first either:**
   - confirming it has zero callers in the project (grep the symbol name), or
   - creating the replacement at the destination *first*, building, and then removing the original.

   Additive-first, destructive-second. Always.

4. **One logical change per response.** Do not bundle "extract a function" with "rename a variable" with "tighten a closure" in one diff. Smaller diffs survive context loss.

5. **Build after every change.** If a build tool is available (`xcodebuild`, `BuildProject` MCP, etc.), invoke it. Do not proceed to the next change until the build is green. If it goes red, fix it before doing anything else — do not pile on more changes hoping to fix it later.

## State verification

6. **Before each edit, grep for the symbols you're about to touch and list line numbers.** Reading 30 lines and editing a function that lives 600 lines later in the file is how content gets dropped.

7. **After each edit, re-grep the same symbols and confirm they exist (or are intentionally gone) at the expected locations.** Do not trust that the diff produced what you intended without verifying.

8. **If you ever read a file and the content looks unexpectedly short or ends mid-function, stop immediately and report it.** Do not write to that file. The previous response may have truncated it.

## Git discipline

9. **Commit and push to remote after every successful item.** Use a descriptive message that includes the item number if one was assigned. Smaller commits make Path-B recovery cheap.

10. **Never `git add -A` or `git add .`** — stage only the files you intentionally changed. This prevents accidentally committing unrelated working-tree drift.

11. **Check `git status` before starting work and after each commit.** If there are unrelated uncommitted changes, ask the user before touching them. Do not "clean up" working-tree state you didn't create.

## Scope discipline

12. **Do not refactor outside what the task requires.** A bug fix doesn't need surrounding cleanup. A one-shot operation doesn't need a helper. If you see a tempting drive-by improvement, leave a comment in your reply suggesting it as a separate task — do not do it.

13. **If the user provided a numbered task list, work items in the listed order.** Stop after each item; do not skip ahead.

14. **Preserve out-of-scope working features.** If the file you're editing contains an unrelated feature (per-folder windows, custom initializers, etc.), do not modify those lines. If your change requires touching them, ask first.

## Comments

15. **Default to writing no comments.** Only add a comment when the *why* is non-obvious — a hidden constraint, a subtle invariant, a workaround. Do not narrate what the code does. Do not write multi-line docstrings unless asked.

## When unsure, stop

16. **If a requirement is ambiguous, a build keeps failing, or you would have to guess, stop and ask the user.** Guessing has produced the past truncation incidents.


