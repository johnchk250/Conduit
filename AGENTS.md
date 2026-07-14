# AGENTS.md

## Goal

Work efficiently inside this repository. Make the smallest correct change, avoid repetitive inspection, and stop once the task is complete and validated.

## Core workflow

1. Inspect only the files and symbols relevant to the task.
2. Make related edits in one coherent pass where practical.
3. Format changed files once after editing.
4. Run the narrowest relevant validation.
5. Fix only real failures.
6. Review the final diff once.
7. Stop when the requested change is complete.

## Avoid unnecessary repetition

Do not repeat a command unless:
- the code changed after the previous run;
- the previous command failed;
- the output was incomplete or truncated; or
- new evidence makes another run necessary.

In particular:
- Do not run `git diff` repeatedly on unchanged files.
- Do not rerun formatting after a successful format unless the file changed again.
- Do not rerun analysis or tests merely for reassurance.
- Do not reread an entire large file when a focused section is enough.
- Do not repeat repository-wide searches after the relevant files are known.
- Do not retry the same blocked permission or environment operation with minor command variations.

## Inspection

Before editing:
- Read this file.
- Check `git status --short` once.
- Open the named file or search for the exact relevant symbol.
- Expand to callers, tests, or related files only when needed.

Avoid broad repository scans unless the task genuinely requires them.

Ignore generated and dependency directories unless directly relevant:
- `.git/`
- `.dart_tool/`
- `build/`
- `node_modules/`
- `coverage/`
- dependency caches
- generated platform output

## Editing

- Prefer focused edits over whole-file rewrites.
- Batch related changes instead of making many tiny edit cycles.
- Preserve existing architecture, naming, formatting, and style.
- Do not refactor, rename, clean up, or modernize unrelated code.
- Do not modify unrelated user changes.
- Do not add dependencies unless required.
- Do not edit generated files manually unless the project expects it.

## Validation

Use the cheapest relevant checks first.

For a localized Flutter/Dart change, the default sequence is:

1. Format only changed Dart files.
2. Run targeted analysis on the changed file or relevant path.
3. Run targeted tests only when relevant tests exist.
4. Run `git diff --check`.
5. Review one final diff for the changed files.

Use full-project analysis, the full test suite, or a full build only when:
- shared interfaces changed;
- multiple modules are affected;
- targeted checks are insufficient;
- the task explicitly requests full validation; or
- targeted checks reveal broader problems.

Do not run `flutter clean`, dependency installation, code generation, or release builds unless there is a specific reason.

## Git usage

At the start:
- Run `git status --short` once.

At the end:
- Run `git diff --check` once.
- Review `git diff -- <changed-files>` once.

Do not:
- repeatedly run diffs without intervening edits;
- stage, commit, stash, reset, clean, restore, rebase, or push unless explicitly asked;
- modify `.git` internals.

## Permission and environment failures

Work inside the repository whenever possible.

If a command is blocked:
1. Read the actual error.
2. Determine whether it is a code, path, dependency, permission, or environment problem.
3. Try one evidence-based correction.
4. If the same blocker occurs twice, stop retrying and report it clearly.

Do not bypass sandboxing, alter Windows security settings, change global PATH, install global tools, or request elevation unless the task truly requires it.

## Command output

Keep tool output focused:
- prefer targeted searches;
- limit large file reads to relevant ranges;
- filter very large logs to relevant errors;
- avoid printing full generated files, lockfiles, dependency trees, or build logs.

If output is truncated, rerun with a narrower command instead of repeating the same broad command.

## Definition of done

Stop working when:
- the requested behavior is implemented;
- only relevant files were changed;
- changed files are formatted;
- the narrowest appropriate validation passed;
- one final diff review was completed; and
- no unresolved issue remains.

Do not continue running tools after these conditions are met.

## Final response

Report only:
- what changed;
- which validation was run and whether it passed;
- any unresolved blocker or validation not performed.

Do not reproduce the full command history.
