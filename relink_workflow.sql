/* =====================================================================================
   relink_workflow.sql   (SQL Server 2016+, run in SSMS)   ONE script, no other tools.

   Fixes running instances stuck with "Workflow definition of '...' is deleted" after a
   workflow document was deleted and recreated (same name, new GUIDs): it re-links them
   to the new definition. The old->new GUID map is built inside the database from the
   System.WorkflowVersion.modeljson snapshots.

   HOW TO USE
     1. Run it as-is (@WorkflowName = NULL): read-only list of recreated workflows.
     2. Put a name from that list in @WorkflowName, keep @Commit = 0, run again:
        dry run -> full report, everything rolled back. Read the report.
     3. STOP the app (every instance), take a FULL backup, set @Commit = 1, run.
     4. Start the app and check the re-linked instances in the workflow admin pages.

   NOT a Mendix-supported operation (it writes System-module workflow tables):
   rehearse on a restored copy of production first. The script is ONE batch (no GO),
   so any RETURN or error stops everything.
   ===================================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @WorkflowName  nvarchar(400) = NULL;  -- e.g. N'CarRental.WF_RentalContract_Approval'; NULL = list candidates only
DECLARE @Commit        bit           = 0;     -- 0 = dry run (ROLLBACK), 1 = COMMIT (app stopped, backup taken)
DECLARE @AllowFallback bit           = 0;     -- 1 = accept a caption-matched map (workflow changed after recreation), only after reviewing it

/* ---------- A. candidates (read-only, always shown) ---------- */
SELECT o.name AS workflow_name,
       COUNT(*) AS obsolete_definitions,
       (SELECT COUNT(*) FROM [system$workflow_workflowdefinition] wd
          JOIN [system$workflow] w ON w.id = wd.[system$workflowid]
          JOIN [system$workflowdefinition] d2 ON d2.id = wd.[system$workflowdefinitionid]
         WHERE d2.name = o.name AND d2.isobsolete = 1 AND w.state = N'Incompatible') AS stuck_instances,
       CASE WHEN EXISTS (SELECT 1 FROM [system$workflowdefinition] n WHERE n.name = o.name AND n.isobsolete = 0)
            THEN N'recreated - can re-link' ELSE N'no active definition with this name (deleted or renamed)' END AS status
FROM [system$workflowdefinition] o
WHERE o.isobsolete = 1
  AND EXISTS (SELECT 1 FROM [system$workflow_workflowdefinition] wd
                JOIN [system$workflow] w ON w.id = wd.[system$workflowid]
               WHERE wd.[system$workflowdefinitionid] = o.id
                 AND w.state IN (N'InProgress', N'Paused', N'Incompatible', N'Failed'))
GROUP BY o.name
ORDER BY o.name;

IF @WorkflowName IS NULL
BEGIN
    PRINT N'Candidates listed above. Put one name in @WorkflowName and run again (keep @Commit = 0 for the dry run).';
    RETURN;
END;

/* ---------- B. pre-flight: tested table layout + OPENJSON available ---------- */
DECLARE @MxVersion nvarchar(50) = (SELECT TOP 1 mendixversion FROM [mendixsystem$version]);
PRINT N'Mendix version recorded in DB: ' + ISNULL(@MxVersion, N'?') + N' (layout verified on 11.12.x)';

IF (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID()) < 130
BEGIN
    RAISERROR(N'Database compatibility level is below 130, so OPENJSON is unavailable. Nothing was changed.', 16, 1);
    RETURN;
END;

DECLARE @expected TABLE (assoc nvarchar(200) PRIMARY KEY, tbl nvarchar(200), pcol nvarchar(200), ccol nvarchar(200));
INSERT INTO @expected (assoc, tbl, pcol, ccol) VALUES
 (N'System.Workflow_WorkflowDefinition',                      N'system$workflow_workflowdefinition',                      N'system$workflowid',              N'system$workflowdefinitionid'),
 (N'System.Workflow_CurrentActivity',                         N'system$workflow_currentactivity',                         N'system$workflowid',              N'system$workflowactivityid'),
 (N'System.WorkflowActivity_Workflow',                        N'system$workflowactivity',                                 N'id',                             N'system$workflowactivity_workflow'),
 (N'System.WorkflowActivity_WorkflowVersion',                 N'system$workflowactivity',                                 N'id',                             N'system$workflowactivity_workflowversion'),
 (N'System.WorkflowDefinition_CurrentWorkflowVersion',        N'system$workflowdefinition',                               N'id',                             N'system$workflowdefinition_currentworkflowversion'),
 (N'System.WorkflowUserTask_Workflow',                        N'system$workflowusertask_workflow',                        N'system$workflowusertaskid',      N'system$workflowid'),
 (N'System.WorkflowUserTask_WorkflowUserTaskDefinition',      N'system$workflowusertask_workflowusertaskdefinition',      N'system$workflowusertaskid',      N'system$workflowusertaskdefinitionid'),
 (N'System.WorkflowEndedUserTask_Workflow',                   N'system$workflowendedusertask_workflow',                   N'system$workflowendedusertaskid', N'system$workflowid'),
 (N'System.WorkflowEndedUserTask_WorkflowUserTaskDefinition', N'system$workflowendedusertask_workflowusertaskdefinition', N'system$workflowendedusertaskid', N'system$workflowusertaskdefinitionid'),
 (N'System.WorkflowUserTaskDefinition_WorkflowDefinition',    N'system$workflowusertaskdefinition_workflowdefinition',    N'system$workflowusertaskdefinitionid', N'system$workflowdefinitionid'),
 (N'System.WorkflowSubProcess_Workflow',                      N'system$workflowsubprocess_workflow',                      N'system$workflowsubprocessid',    N'system$workflowid'),
 (N'System.WorkflowSubProcess_WorkflowSubProcessDefinition',  N'system$workflowsubprocess_workflowsubprocessdefinition',  N'system$workflowsubprocessid',    N'system$workflowsubprocessdefinitionid');

IF EXISTS (SELECT 1 FROM @expected e LEFT JOIN [mendixsystem$association] a ON a.association_name = e.assoc
           WHERE a.association_name IS NULL OR a.table_name <> e.tbl OR a.parent_column_name <> e.pcol OR a.child_column_name <> e.ccol)
   OR COL_LENGTH(N'system$workflowactivity', N'modelguid') IS NULL
   OR COL_LENGTH(N'system$workflowactivity', N'outcomemodelguid') IS NULL
   OR COL_LENGTH(N'system$workflowdefinition', N'modelguid') IS NULL
   OR COL_LENGTH(N'system$workflowusertaskdefinition', N'modelguid') IS NULL
   OR COL_LENGTH(N'system$workflowsubprocessdefinition', N'modelguid') IS NULL
   OR COL_LENGTH(N'system$workflow', N'previousstate') IS NULL
   OR COL_LENGTH(N'system$workflowversion', N'modeljson') IS NULL
BEGIN
    SELECT e.assoc, a.table_name, a.parent_column_name, a.child_column_name,
           CASE WHEN a.association_name IS NULL THEN N'MISSING'
                WHEN a.table_name = e.tbl AND a.parent_column_name = e.pcol AND a.child_column_name = e.ccol THEN N'ok'
                ELSE N'DIFFERENT' END AS preflight
    FROM @expected e LEFT JOIN [mendixsystem$association] a ON a.association_name = e.assoc ORDER BY e.assoc;
    RAISERROR(N'PRE-FLIGHT FAILED: workflow tables differ from the verified layout. Nothing was changed.', 16, 1);
    RETURN;
END;
PRINT N'Pre-flight: ok';

/* ---------- C. definitions: every obsolete row with this name -> the one active row ---------- */
DECLARE @NewDef bigint, @NewVer bigint, @n int;
SELECT @NewDef = id, @NewVer = [system$workflowdefinition_currentworkflowversion]
FROM [system$workflowdefinition] WHERE name = @WorkflowName AND isobsolete = 0;

IF OBJECT_ID(N'tempdb..#olddef') IS NOT NULL DROP TABLE #olddef;
CREATE TABLE #olddef (def_id bigint NOT NULL PRIMARY KEY);
INSERT INTO #olddef (def_id) SELECT id FROM [system$workflowdefinition] WHERE name = @WorkflowName AND isobsolete = 1;

IF @NewDef IS NULL OR @NewVer IS NULL OR NOT EXISTS (SELECT 1 FROM #olddef)
BEGIN
    RAISERROR(N'Need one ACTIVE and at least one OBSOLETE definition named @WorkflowName (see the candidate list). Nothing was changed.', 16, 1);
    RETURN;
END;
SELECT d.id AS definition_id, d.name, d.modelguid, CASE WHEN d.isobsolete = 1 THEN N'OLD (obsolete)' ELSE N'NEW (active)' END AS role
FROM [system$workflowdefinition] d WHERE d.name = @WorkflowName ORDER BY d.isobsolete DESC, d.id;

/* ---------- D. snapshots to compare: old versions used by open instances + each old current version ---------- */
IF OBJECT_ID(N'tempdb..#oldver') IS NOT NULL DROP TABLE #oldver;
CREATE TABLE #oldver (ver_id bigint NOT NULL PRIMARY KEY);
INSERT INTO #oldver (ver_id)
SELECT a.[system$workflowactivity_workflowversion]
FROM [system$workflow_workflowdefinition] wd
JOIN [system$workflow] w ON w.id = wd.[system$workflowid]
JOIN [system$workflowactivity] a ON a.[system$workflowactivity_workflow] = w.id
WHERE wd.[system$workflowdefinitionid] IN (SELECT def_id FROM #olddef)
  AND w.state IN (N'InProgress', N'Paused', N'Incompatible', N'Failed')
  AND a.[system$workflowactivity_workflowversion] IS NOT NULL
UNION
SELECT d.[system$workflowdefinition_currentworkflowversion]
FROM [system$workflowdefinition] d
WHERE d.id IN (SELECT def_id FROM #olddef) AND d.[system$workflowdefinition_currentworkflowversion] IS NOT NULL;

/* ---------- E. flatten every snapshot into (path, key, value) leaves with OPENJSON ---------- */
IF OBJECT_ID(N'tempdb..#leaf') IS NOT NULL DROP TABLE #leaf;
-- (collations pinned: OPENJSON keys are Latin1_General_BIN2, and tempdb may differ from the app DB)
CREATE TABLE #leaf (ver_id bigint NOT NULL, path nvarchar(4000) COLLATE Latin1_General_BIN2 NOT NULL,
                    parent nvarchar(4000) COLLATE Latin1_General_BIN2 NOT NULL, k nvarchar(4000) COLLATE Latin1_General_BIN2 NOT NULL,
                    v nvarchar(max) COLLATE DATABASE_DEFAULT NULL, t int NOT NULL);
WITH tree (ver_id, path, parent, k, val, t) AS (
    SELECT v.id, CAST(N'$' AS nvarchar(4000)) COLLATE Latin1_General_BIN2, CAST(N'' AS nvarchar(4000)) COLLATE Latin1_General_BIN2,
           CAST(N'' AS nvarchar(4000)) COLLATE Latin1_General_BIN2, CAST(v.modeljson AS nvarchar(max)), 5
    FROM [system$workflowversion] v
    WHERE v.id = @NewVer OR v.id IN (SELECT ver_id FROM #oldver)
    UNION ALL
    SELECT tr.ver_id,
           CAST(tr.path + CASE WHEN tr.t = 4 THEN N'[' + j.[key] + N']' ELSE N'.' + j.[key] END AS nvarchar(4000)) COLLATE Latin1_General_BIN2,
           tr.path, CAST(j.[key] AS nvarchar(4000)) COLLATE Latin1_General_BIN2, CAST(j.[value] AS nvarchar(max)), CAST(j.[type] AS int)
    FROM tree tr CROSS APPLY OPENJSON(tr.val) j
    WHERE tr.t IN (4, 5)
)
INSERT INTO #leaf (ver_id, path, parent, k, v, t)
SELECT ver_id, path, parent, k, val, t FROM tree WHERE t NOT IN (4, 5)
OPTION (MAXRECURSION 0);

DECLARE @g nvarchar(400) = REPLICATE(N'[0-9a-f]', 8) + N'-' + REPLICATE(N'[0-9a-f]', 4) + N'-' + REPLICATE(N'[0-9a-f]', 4)
                         + N'-' + REPLICATE(N'[0-9a-f]', 4) + N'-' + REPLICATE(N'[0-9a-f]', 12);

/* ---------- F. map mode per old snapshot: EXACT = same shape, only GUIDs differ ---------- */
IF OBJECT_ID(N'tempdb..#vermode') IS NOT NULL DROP TABLE #vermode;
CREATE TABLE #vermode (ver_id bigint NOT NULL PRIMARY KEY, mode nvarchar(10) NOT NULL, differences int NOT NULL);
INSERT INTO #vermode (ver_id, mode, differences)
SELECT ov.ver_id, CASE WHEN x.diffs = 0 THEN N'EXACT' ELSE N'FALLBACK' END, x.diffs
FROM #oldver ov
CROSS APPLY (
    SELECT COUNT(*) AS diffs
    FROM (SELECT path, v, t FROM #leaf WHERE ver_id = ov.ver_id) o
    FULL OUTER JOIN (SELECT path, v, t FROM #leaf WHERE ver_id = @NewVer) nw
      ON nw.path COLLATE Latin1_General_BIN2 = o.path COLLATE Latin1_General_BIN2
    WHERE o.path IS NULL OR nw.path IS NULL OR o.t <> nw.t
       OR (NOT (LEN(o.v) = 36 AND o.v LIKE @g AND LEN(nw.v) = 36 AND nw.v LIKE @g)
           AND ISNULL(o.v, N'') COLLATE Latin1_General_BIN2 <> ISNULL(nw.v, N'') COLLATE Latin1_General_BIN2)
) x;

IF OBJECT_ID(N'tempdb..#pairs') IS NOT NULL DROP TABLE #pairs;
CREATE TABLE #pairs (old_guid nvarchar(36) COLLATE DATABASE_DEFAULT NOT NULL, new_guid nvarchar(36) COLLATE DATABASE_DEFAULT NOT NULL,
                     src nvarchar(10) COLLATE DATABASE_DEFAULT NOT NULL);

-- EXACT: GUIDs at the same JSON path pair up
INSERT INTO #pairs (old_guid, new_guid, src)
SELECT DISTINCT CAST(o.v AS nvarchar(36)), CAST(nw.v AS nvarchar(36)), N'EXACT'
FROM #vermode m
JOIN #leaf o  ON o.ver_id = m.ver_id
JOIN #leaf nw ON nw.ver_id = @NewVer AND nw.path COLLATE Latin1_General_BIN2 = o.path COLLATE Latin1_General_BIN2
WHERE m.mode = N'EXACT'
  AND LEN(o.v) = 36 AND o.v LIKE @g AND LEN(nw.v) = 36 AND nw.v LIKE @g
  AND o.v <> nw.v;

-- FALLBACK: activities by (typeName, caption) when unique on both sides, then their outcomes by description
IF OBJECT_ID(N'tempdb..#act') IS NOT NULL DROP TABLE #act;
CREATE TABLE #act (ver_id bigint NOT NULL, p nvarchar(4000) COLLATE Latin1_General_BIN2 NOT NULL, guid nvarchar(36) COLLATE DATABASE_DEFAULT NOT NULL,
                   typ nvarchar(400) COLLATE DATABASE_DEFAULT NULL, cap nvarchar(4000) COLLATE DATABASE_DEFAULT NULL);
INSERT INTO #act (ver_id, p, guid, typ, cap)
SELECT l.ver_id, l.parent, CAST(l.v AS nvarchar(36)),
       (SELECT TOP 1 CAST(x.v AS nvarchar(400)) FROM #leaf x WHERE x.ver_id = l.ver_id AND x.parent = l.parent AND x.k COLLATE Latin1_General_BIN2 = N'typeName'),
       (SELECT TOP 1 CAST(x.v AS nvarchar(4000)) FROM #leaf x WHERE x.ver_id = l.ver_id AND x.parent = l.parent AND x.k COLLATE Latin1_General_BIN2 = N'caption')
FROM #leaf l
WHERE l.k COLLATE Latin1_General_BIN2 = N'modelID' AND LEN(l.v) = 36 AND l.v LIKE @g;

IF OBJECT_ID(N'tempdb..#outc') IS NOT NULL DROP TABLE #outc;
CREATE TABLE #outc (ver_id bigint NOT NULL, guid nvarchar(36) COLLATE DATABASE_DEFAULT NOT NULL, act_guid nvarchar(36) COLLATE DATABASE_DEFAULT NULL,
                    descr nvarchar(4000) COLLATE DATABASE_DEFAULT NULL);
INSERT INTO #outc (ver_id, guid, act_guid, descr)
SELECT l.ver_id, CAST(l.v AS nvarchar(36)), a.guid,
       (SELECT TOP 1 CAST(x.v AS nvarchar(4000)) FROM #leaf x WHERE x.ver_id = l.ver_id AND x.parent = l.parent AND x.k COLLATE Latin1_General_BIN2 = N'description')
FROM #leaf l
CROSS APPLY (SELECT LEFT(l.parent, LEN(l.parent) - CHARINDEX(N'[', REVERSE(l.parent))) AS arr) q
LEFT JOIN #act a ON a.ver_id = l.ver_id AND RIGHT(q.arr, 9) = N'.outcomes' AND a.p = LEFT(q.arr, LEN(q.arr) - 9)
WHERE l.k COLLATE Latin1_General_BIN2 = N'modelId' AND LEN(l.v) = 36 AND l.v LIKE @g;

INSERT INTO #pairs (old_guid, new_guid, src)
SELECT oa.guid, na.guid, N'FALLBACK'
FROM #vermode m
JOIN #act oa ON oa.ver_id = m.ver_id
JOIN #act na ON na.ver_id = @NewVer AND na.typ = oa.typ AND na.cap COLLATE Latin1_General_BIN2 = oa.cap COLLATE Latin1_General_BIN2
WHERE m.mode = N'FALLBACK'
  AND (SELECT COUNT(*) FROM #act x WHERE x.ver_id = oa.ver_id AND x.typ = oa.typ AND x.cap COLLATE Latin1_General_BIN2 = oa.cap COLLATE Latin1_General_BIN2) = 1
  AND (SELECT COUNT(*) FROM #act x WHERE x.ver_id = @NewVer AND x.typ = oa.typ AND x.cap COLLATE Latin1_General_BIN2 = oa.cap COLLATE Latin1_General_BIN2) = 1;

INSERT INTO #pairs (old_guid, new_guid, src)
SELECT oo.guid, no.guid, N'FALLBACK'
FROM #vermode m
JOIN #outc oo ON oo.ver_id = m.ver_id
JOIN #pairs pa ON pa.old_guid = oo.act_guid AND pa.src = N'FALLBACK'
JOIN #outc no ON no.ver_id = @NewVer AND no.act_guid = pa.new_guid AND no.descr COLLATE Latin1_General_BIN2 = oo.descr COLLATE Latin1_General_BIN2
WHERE m.mode = N'FALLBACK';

-- one old GUID must never map to two different new GUIDs
IF EXISTS (SELECT old_guid FROM #pairs GROUP BY old_guid HAVING COUNT(DISTINCT new_guid) > 1)
BEGIN
    SELECT old_guid, new_guid, src FROM #pairs
    WHERE old_guid IN (SELECT old_guid FROM #pairs GROUP BY old_guid HAVING COUNT(DISTINCT new_guid) > 1) ORDER BY old_guid;
    RAISERROR(N'GUID map is inconsistent (one old GUID pairs with several new ones). Nothing was changed.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'tempdb..#wfrelink_map') IS NOT NULL DROP TABLE #wfrelink_map;
CREATE TABLE #wfrelink_map (old_guid nvarchar(36) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, new_guid nvarchar(36) COLLATE DATABASE_DEFAULT NOT NULL);
INSERT INTO #wfrelink_map (old_guid, new_guid) SELECT DISTINCT old_guid, new_guid FROM #pairs WHERE old_guid <> new_guid;

-- report: mode per snapshot, the map, and old activities/outcomes that found no partner
SELECT ver_id AS old_snapshot_version_id, mode AS map_mode, differences AS shape_differences FROM #vermode ORDER BY ver_id;
SELECT m.old_guid, m.new_guid,
       COALESCE((SELECT TOP 1 a.typ + N' ''' + a.cap + N'''' FROM #act a WHERE a.guid = m.old_guid),
                (SELECT TOP 1 N'outcome ''' + o.descr + N'''' FROM #outc o WHERE o.guid = m.old_guid), N'(reference)') AS what
FROM #wfrelink_map m ORDER BY what;
SELECT DISTINCT u.guid AS unmapped_old_guid, u.what
FROM (SELECT a.guid, a.typ + N' ''' + a.cap + N'''' AS what FROM #act a WHERE a.ver_id IN (SELECT ver_id FROM #oldver)
      UNION ALL
      SELECT o.guid, N'outcome ''' + o.descr + N'''' FROM #outc o WHERE o.ver_id IN (SELECT ver_id FROM #oldver)) u
WHERE NOT EXISTS (SELECT 1 FROM #wfrelink_map m WHERE m.old_guid = u.guid);

DECLARE @UsesFallback bit = CASE WHEN EXISTS (SELECT 1 FROM #vermode WHERE mode = N'FALLBACK') THEN 1 ELSE 0 END;
IF @UsesFallback = 1
    PRINT N'NOTE: the workflow changed after it was recreated, so (part of) the map was built by caption matching. Review the map above; set @AllowFallback = 1 to allow a commit.';

/* ---------- G. targets: Incompatible instances on OLD whose CURRENT activities are all mapped ---------- */
IF OBJECT_ID(N'tempdb..#wfrelink_target') IS NOT NULL DROP TABLE #wfrelink_target;
CREATE TABLE #wfrelink_target (wf_id bigint NOT NULL PRIMARY KEY);
INSERT INTO #wfrelink_target (wf_id)
SELECT w.id
FROM [system$workflow] w
JOIN [system$workflow_workflowdefinition] wd ON wd.[system$workflowid] = w.id
WHERE wd.[system$workflowdefinitionid] IN (SELECT def_id FROM #olddef)
  AND w.state = N'Incompatible'
  AND NOT EXISTS (SELECT 1
                  FROM [system$workflow_currentactivity] ca
                  JOIN [system$workflowactivity] a ON a.id = ca.[system$workflowactivityid]
                  WHERE ca.[system$workflowid] = w.id
                    AND NOT EXISTS (SELECT 1 FROM #wfrelink_map m WHERE m.old_guid = a.modelguid));

SELECT w.id, w.name, w.state, w.previousstate,
       CASE WHEN t.wf_id IS NULL THEN N'EXCLUDED - a current activity has no match in the new workflow (abort/restart it manually)'
            ELSE N'WILL RE-LINK' END AS [plan]
FROM [system$workflow] w
JOIN [system$workflow_workflowdefinition] wd ON wd.[system$workflowid] = w.id
LEFT JOIN #wfrelink_target t ON t.wf_id = w.id
WHERE wd.[system$workflowdefinitionid] IN (SELECT def_id FROM #olddef)
  AND w.state IN (N'Incompatible', N'InProgress', N'Paused', N'Failed')
ORDER BY w.id;

/* ---------- H. re-link, ONE transaction ---------- */
BEGIN TRANSACTION;

UPDATE a SET a.modelguid = m.new_guid
FROM [system$workflowactivity] a JOIN #wfrelink_map m ON m.old_guid = a.modelguid
WHERE a.[system$workflowactivity_workflow] IN (SELECT wf_id FROM #wfrelink_target);
SET @n = @@ROWCOUNT; PRINT N'H.1 activity GUIDs           : ' + CAST(@n AS nvarchar(20));

UPDATE a SET a.outcomemodelguid = m.new_guid
FROM [system$workflowactivity] a JOIN #wfrelink_map m ON m.old_guid = a.outcomemodelguid
WHERE a.[system$workflowactivity_workflow] IN (SELECT wf_id FROM #wfrelink_target);
SET @n = @@ROWCOUNT; PRINT N'H.2 selected-outcome GUIDs   : ' + CAST(@n AS nvarchar(20));

UPDATE a SET a.[system$workflowactivity_workflowversion] = @NewVer
FROM [system$workflowactivity] a
WHERE a.[system$workflowactivity_workflow] IN (SELECT wf_id FROM #wfrelink_target);
SET @n = @@ROWCOUNT; PRINT N'H.3 activities -> new version: ' + CAST(@n AS nvarchar(20));

UPDATE x SET x.[system$workflowusertaskdefinitionid] = nd.id
FROM [system$workflowusertask_workflowusertaskdefinition] x
JOIN [system$workflowusertask_workflow] tw ON tw.[system$workflowusertaskid] = x.[system$workflowusertaskid]
JOIN [system$workflowusertaskdefinition] od ON od.id = x.[system$workflowusertaskdefinitionid]
JOIN #wfrelink_map m ON m.old_guid = od.modelguid
JOIN [system$workflowusertaskdefinition] nd ON nd.modelguid = m.new_guid
WHERE tw.[system$workflowid] IN (SELECT wf_id FROM #wfrelink_target);
SET @n = @@ROWCOUNT; PRINT N'H.4 open user tasks          : ' + CAST(@n AS nvarchar(20));

UPDATE x SET x.[system$workflowusertaskdefinitionid] = nd.id
FROM [system$workflowendedusertask_workflowusertaskdefinition] x
JOIN [system$workflowendedusertask_workflow] ew ON ew.[system$workflowendedusertaskid] = x.[system$workflowendedusertaskid]
JOIN [system$workflowusertaskdefinition] od ON od.id = x.[system$workflowusertaskdefinitionid]
JOIN #wfrelink_map m ON m.old_guid = od.modelguid
JOIN [system$workflowusertaskdefinition] nd ON nd.modelguid = m.new_guid
WHERE ew.[system$workflowid] IN (SELECT wf_id FROM #wfrelink_target);
SET @n = @@ROWCOUNT; PRINT N'H.5 ended user tasks         : ' + CAST(@n AS nvarchar(20));

UPDATE x SET x.[system$workflowsubprocessdefinitionid] = nd.id
FROM [system$workflowsubprocess_workflowsubprocessdefinition] x
JOIN [system$workflowsubprocess_workflow] sw ON sw.[system$workflowsubprocessid] = x.[system$workflowsubprocessid]
JOIN [system$workflowsubprocessdefinition] od ON od.id = x.[system$workflowsubprocessdefinitionid]
JOIN #wfrelink_map m ON m.old_guid = od.modelguid
JOIN [system$workflowsubprocessdefinition] nd ON nd.modelguid = m.new_guid
WHERE sw.[system$workflowid] IN (SELECT wf_id FROM #wfrelink_target);
SET @n = @@ROWCOUNT; PRINT N'H.6 event sub-processes      : ' + CAST(@n AS nvarchar(20));

UPDATE wd SET wd.[system$workflowdefinitionid] = @NewDef
FROM [system$workflow_workflowdefinition] wd
WHERE wd.[system$workflowid] IN (SELECT wf_id FROM #wfrelink_target);
SET @n = @@ROWCOUNT; PRINT N'H.7 instances -> new def     : ' + CAST(@n AS nvarchar(20));

IF OBJECT_ID(N'workflowcommons$workflowview_workflowdefinition') IS NOT NULL
   AND OBJECT_ID(N'workflowcommons$workflowview_workflow') IS NOT NULL
    EXEC sp_executesql N'
        UPDATE vd SET vd.[system$workflowdefinitionid] = @NewDef
        FROM [workflowcommons$workflowview_workflowdefinition] vd
        JOIN [workflowcommons$workflowview_workflow] vw ON vw.[workflowcommons$workflowviewid] = vd.[workflowcommons$workflowviewid]
        WHERE vw.[system$workflowid] IN (SELECT wf_id FROM #wfrelink_target);
        PRINT N''H.8 WC WorkflowView links     : '' + CAST(@@ROWCOUNT AS nvarchar(20));', N'@NewDef bigint', @NewDef = @NewDef;
IF OBJECT_ID(N'workflowcommons$usertaskview_workflowusertaskdefinition') IS NOT NULL
   AND OBJECT_ID(N'workflowcommons$usertaskview_workflowview') IS NOT NULL
   AND OBJECT_ID(N'workflowcommons$workflowview_workflow') IS NOT NULL
    EXEC sp_executesql N'
        UPDATE ud SET ud.[system$workflowusertaskdefinitionid] = nd.id
        FROM [workflowcommons$usertaskview_workflowusertaskdefinition] ud
        JOIN [workflowcommons$usertaskview_workflowview] uv ON uv.[workflowcommons$usertaskviewid] = ud.[workflowcommons$usertaskviewid]
        JOIN [workflowcommons$workflowview_workflow] vw ON vw.[workflowcommons$workflowviewid] = uv.[workflowcommons$workflowviewid]
        JOIN [system$workflowusertaskdefinition] od ON od.id = ud.[system$workflowusertaskdefinitionid]
        JOIN #wfrelink_map m ON m.old_guid = od.modelguid
        JOIN [system$workflowusertaskdefinition] nd ON nd.modelguid = m.new_guid
        WHERE vw.[system$workflowid] IN (SELECT wf_id FROM #wfrelink_target);
        PRINT N''H.8 WC UserTaskView links     : '' + CAST(@@ROWCOUNT AS nvarchar(20));';

UPDATE w SET w.state = w.previousstate, w.previousstate = NULL, w.reason = NULL,
             w.canberestarted = 1, w.canbecontinued = 1, w.canapplyjumpto = 1
FROM [system$workflow] w
WHERE w.id IN (SELECT wf_id FROM #wfrelink_target)
  AND w.state = N'Incompatible' AND w.previousstate IS NOT NULL;
SET @n = @@ROWCOUNT; PRINT N'H.9 state restored           : ' + CAST(@n AS nvarchar(20));

/* ---------- I. post-checks inside the transaction ---------- */
DECLARE @bad_current int = (
    SELECT COUNT(*) FROM [system$workflow_currentactivity] ca
    JOIN [system$workflowactivity] a ON a.id = ca.[system$workflowactivityid]
    JOIN [system$workflowversion] v ON v.id = @NewVer
    WHERE ca.[system$workflowid] IN (SELECT wf_id FROM #wfrelink_target)
      AND CHARINDEX(a.modelguid, v.modeljson) = 0);
DECLARE @bad_tasks int = (
    SELECT COUNT(*) FROM [system$workflowusertask_workflow] tw
    JOIN [system$workflowusertask_workflowusertaskdefinition] td ON td.[system$workflowusertaskid] = tw.[system$workflowusertaskid]
    JOIN [system$workflowusertaskdefinition_workflowdefinition] dd ON dd.[system$workflowusertaskdefinitionid] = td.[system$workflowusertaskdefinitionid]
    WHERE tw.[system$workflowid] IN (SELECT wf_id FROM #wfrelink_target)
      AND dd.[system$workflowdefinitionid] <> @NewDef);
DECLARE @still_old int = (
    SELECT COUNT(*) FROM [system$workflow_workflowdefinition]
    WHERE [system$workflowid] IN (SELECT wf_id FROM #wfrelink_target) AND [system$workflowdefinitionid] <> @NewDef);

SELECT (SELECT COUNT(*) FROM #wfrelink_target) AS instances_relinked,
       @bad_current AS current_activities_not_in_new_version_MUST_BE_0,
       @bad_tasks   AS open_tasks_on_old_definition_MUST_BE_0,
       @still_old   AS instances_still_on_old_definition_MUST_BE_0;

IF @bad_current > 0 OR @bad_tasks > 0 OR @still_old > 0
BEGIN
    ROLLBACK TRANSACTION;
    RAISERROR(N'POST-CHECK FAILED -> rolled back. Nothing was changed.', 16, 1);
    RETURN;
END;

IF NOT EXISTS (SELECT 1 FROM #wfrelink_target)
BEGIN
    ROLLBACK TRANSACTION;
    PRINT N'=== NOTHING TO RE-LINK: no instance qualified (see the plan above). Nothing was changed. ===';
    RETURN;
END;

IF @Commit = 1 AND (@UsesFallback = 0 OR @AllowFallback = 1)
BEGIN
    COMMIT TRANSACTION;
    PRINT N'=== COMMITTED: start the app and check the re-linked instances ===';
END
ELSE
BEGIN
    ROLLBACK TRANSACTION;
    IF @Commit = 1
        PRINT N'=== NOT COMMITTED: the map uses caption matching; review it, then set @AllowFallback = 1 ===';
    ELSE
        PRINT N'=== DRY RUN: rolled back. Review the report, then stop the app, back up, set @Commit = 1 ===';
END;
