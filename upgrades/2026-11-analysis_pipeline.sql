--
-- upgrades/2026-11-analysis_pipeline.sql
--
-- Upgrade an existing LIMS instance database for the analysis pipeline
-- (multi-stage 2DSA/PCSA jobs submitted from the LIMS queue setup).
--
--  * new table analysisPipeline
--  * new columns pipelineID, rowKind, groupName, stageKey (+ index on pipelineID)
--    in autoflowAnalysis and autoflowAnalysisHistory
--
-- The columns are appended at the end of both tables, so that the
-- "INSERT autoflowAnalysisHistory SELECT * FROM autoflowAnalysis" copy in
-- submitctl.php keeps working. Both tables must always be upgraded together.
--
-- Idempotent (MariaDB IF NOT EXISTS syntax); safe to run more than once.
--
-- Usage: mysql -u us3admin -p <instance_db> < upgrades/2026-11-analysis_pipeline.sql
--

CREATE TABLE IF NOT EXISTS analysisPipeline (
  pipelineID        int(11)      NOT NULL AUTO_INCREMENT,
  name              varchar(255) NOT NULL,
  invID             int(11)      NOT NULL,
  clusterDefault    text         DEFAULT "localhost",
  specJson          json,
  status            enum('SETUP','ACTIVE','FINISHED','CANCELED') NOT NULL DEFAULT 'SETUP',
  createTime        timestamp    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updateTime        timestamp    DEFAULT 0 ON UPDATE CURRENT_TIMESTAMP,
  createUser        varchar(128) DEFAULT (current_user()),
  updateUser        varchar(128) DEFAULT "",

  PRIMARY KEY (pipelineID),
  KEY (invID)
  ) ENGINE=InnoDB;

ALTER TABLE autoflowAnalysis
  ADD COLUMN IF NOT EXISTS pipelineID int(11)     DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS rowKind    enum('triple','group') NOT NULL DEFAULT 'triple',
  ADD COLUMN IF NOT EXISTS groupName  varchar(80) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS stageKey   varchar(32) DEFAULT NULL,
  ADD KEY IF NOT EXISTS pipelineID (pipelineID);

ALTER TABLE autoflowAnalysisHistory
  ADD COLUMN IF NOT EXISTS pipelineID int(11)     DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS rowKind    enum('triple','group') NOT NULL DEFAULT 'triple',
  ADD COLUMN IF NOT EXISTS groupName  varchar(80) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS stageKey   varchar(32) DEFAULT NULL,
  ADD KEY IF NOT EXISTS pipelineID (pipelineID);

-- Sanity check: both tables must have identical column lists (history copy uses SELECT *)
SELECT IF(
  ( SELECT GROUP_CONCAT( COLUMN_NAME ORDER BY ORDINAL_POSITION )
    FROM   information_schema.COLUMNS
    WHERE  TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'autoflowAnalysis' ) =
  ( SELECT GROUP_CONCAT( COLUMN_NAME ORDER BY ORDINAL_POSITION )
    FROM   information_schema.COLUMNS
    WHERE  TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'autoflowAnalysisHistory' ),
  'OK: autoflowAnalysis and autoflowAnalysisHistory have identical columns',
  'ERROR: autoflowAnalysis and autoflowAnalysisHistory column lists differ' ) AS upgrade_check;
