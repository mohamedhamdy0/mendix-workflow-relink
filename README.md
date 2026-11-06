# Mendix Workflow Re-link (SQL Server)

Recover Mendix workflow instances stuck in **Incompatible** state with the reason
*"Workflow definition of '...' is deleted"* after a workflow document was **deleted and
recreated** in Studio Pro (same name, new model GUIDs).

The script re-links the running instances to the recreated workflow definition, keeping their
progress and history, instead of aborting and restarting them.

> ⚠️ **Not a Mendix-supported operation.** This script writes to System-module workflow tables.
> Use it only as a controlled, last-resort recovery. Always rehearse on a restored copy of
> production first. You use it at your own risk.

## Background

Mendix identifies every workflow element (workflow, activity, outcome, user task) by a
**model GUID**, not by name. Recreating a workflow generates new GUIDs, so on deployment the
runtime marks the old definition obsolete, registers the recreated one as a new definition,
and flags every running instance of the old one as `Incompatible`.

Mendix stores a JSON snapshot of the workflow model for each version
(`System.WorkflowVersion.modeljson`). Both the old and the new snapshots are still in the
database, so the old → new GUID map can be rebuilt entirely inside SQL Server.

## Requirements

- Microsoft SQL Server 2016+ (database compatibility level ≥ 130, for `OPENJSON`)
- Table layout verified on **Mendix 11.12.x** (the script checks the layout before doing anything)
- SSMS or any client that can run a single T-SQL batch

## How to use

1. **List** – run as-is (`@WorkflowName = NULL`). Read-only list of recreated workflows and
   how many instances are stuck.
2. **Dry run** – set `@WorkflowName` to a name from that list, keep `@Commit = 0`, run.
   All updates run inside a transaction and are rolled back. Review the full report.
3. **Commit** – stop the application (all instances), take a **full backup**, set
   `@Commit = 1`, run.
4. **Verify** – start the application and check the re-linked instances.

| Parameter | Meaning |
|---|---|
| `@WorkflowName` | Qualified workflow name, e.g. `MyModule.WF_Approval`. `NULL` = list candidates only |
| `@Commit` | `0` = dry run (rollback), `1` = commit |
| `@AllowFallback` | `1` = allow committing a map built by caption matching (only after reviewing it) |

> Tip: run the dry run on a restored copy or in a quiet window. It executes the real updates
> before rolling back, so it takes locks while it runs.

## How it works

1. **Pre-flight** – checks compatibility level and that the association/column layout in
   `mendixsystem$association` matches the verified layout. Stops on any difference.
2. **Definitions** – finds the active definition and every obsolete definition with the name.
3. **Snapshots** – collects the old model versions used by open instances.
4. **Flatten** – a recursive `OPENJSON` CTE turns each snapshot into `(path, key, value)` leaves.
5. **Map**
   - **EXACT**: same JSON shape, only GUIDs differ → GUIDs at the same path pair up.
   - **FALLBACK**: workflow changed after recreation → activities matched by unique
     `(typeName, caption)`, outcomes by description. Requires `@AllowFallback = 1` to commit.
   - Any old GUID mapping to two new GUIDs stops the script.
6. **Targets** – only `Incompatible` instances whose *current* activities are all mapped.
   Others are reported as excluded (handle them manually).
7. **Re-link (one transaction)** – activity and outcome GUIDs, workflow version, open and ended
   user tasks, event sub-processes, definition link, Workflow Commons views (if present),
   and the state restored from `previousstate`.
8. **Post-checks** – every current activity exists in the new model, every open task belongs to
   the new definition, no instance still on the old one. Any failure rolls everything back.

## Prevention

- Do not delete and recreate a workflow that has running instances; modify it in place.
- Treat deleted workflow documents as a code-review red flag.
- Test deployments against a staging database that contains in-flight workflow instances.

## License

MIT – see [LICENSE](LICENSE).

## Author

Mohamed Hamdy – [LinkedIn](https://www.linkedin.com/in/mohamed-hamdy-425a0211b/)
