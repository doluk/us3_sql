--
-- us3_catalog_procs.sql
--
-- Script to set up the MySQL stored procedures for the US3 system
--   These are the procedures behind US_DataCatalog, the shared record
--   scanner used by us_manage_data and us_data_publication.
--
-- Browsing a data set means walking experiment -> rawData -> editedData ->
-- model -> noise.  Asking for that chain one record at a time costs one
-- round trip per record, which is what made browsing a multi-wavelength run
-- -- hundreds of triples in a single experiment -- painfully slow over a
-- remote connection.  These procedures answer the same questions one
-- experiment at a time instead.
--
-- Run as us3admin
--
-- Results and status codes
-- ------------------------
-- Every procedure here returns a one-column "status" result set first.
-- Only when that status is @OK (0) does a second result set with the data
-- follow; any other status comes alone.  Callers read the data columns by
-- position, so the column order and count of each data set is part of the
-- interface and must not change.
--
-- The status values a caller can see are:
--
--   @OK (0)               the data set follows.  It can be empty; see below.
--   @NOROWS (301)         get_rawData_by_experiment and
--                         get_editedData_by_experiment only: the caller may
--                         read the experiment, but it has no rawData /
--                         editedData.  No data set follows.
--   @NOTPERMITTED (201)   an ordinary user named another investigator, or
--                         asked about an experiment that is not theirs.
--   @NO_EXPERIMENT (508)  the *_by_experiment procedures: no such experiment.
--   @NO_ACCT (102), @BADPASS (104), @INACTIVE (103)
--                         the login itself failed (from check_user).
--
-- "Nothing there" is reported in two ways, and both are kept as they are
-- because clients depend on them:
--
--   - get_rawData_by_experiment and get_editedData_by_experiment answer
--     NOROWS, as the single-record procedures they stand in for
--     (get_rawData, get_editedData) do;
--   - get_experiment_summary, get_model_desc_by_experiment,
--     get_noise_desc_by_experiment, get_rawData_by_person and
--     get_editedData_by_person answer OK with an empty data set.
--
-- A caller must treat NOROWS and "OK, but no rows" alike, as
-- US_DataCatalog in UltraScan3 does.
--
-- Whose records are counted and listed
-- ------------------------------------
-- p_ID names the investigator.  An administrator (userlevel >= @US3_ADMIN)
-- may name anyone, and p_ID = 0 means every investigator.  Anyone else is
-- held to their own records: get_experiment_summary and the *_by_person
-- procedures refuse a p_ID other than 0 or the caller's own ID, and the
-- model and noise procedures ignore p_ID and use the caller's ID.
--
-- Experiments, raw data and edits belong to an investigator through
-- experimentPerson; models through modelPerson; a noise record through the
-- modelPerson row of the model it was fitted with (noise.modelID).  A model
-- or noise record without a modelPerson row is listed, and counted, for
-- nobody, and so is an experiment without an experimentPerson row -- even
-- for an administrator passing p_ID = 0, although an administrator can
-- still open such an experiment with the *_by_experiment procedures.
--
-- An experiment may have several experimentPerson rows; every procedure
-- here still returns each record once.
--
-- Which experiment a record is in
-- -------------------------------
-- Raw data is in the experiment it names, an edit in its raw data's, and a
-- model in its edit's.  A noise record is in the experiment of the model
-- it was fitted with -- noise -> model -> editedData -> rawData -- which
-- is where UltraScan3's catalog files it, under that model.  This is not
-- always the experiment of the edit the noise was computed from
-- (noise.editedDataID): the noise of a global fit is recorded against each
-- data set's edit but fitted with one model, and it is listed and counted
-- with that model's experiment only.  The noise data set still gives the
-- noise record's own editedDataID.
--
-- A model on the special UNASSIGNED edit (editedDataID 1) has no raw data
-- and so no experiment; neither the model nor any noise fitted with it is
-- listed or counted for any experiment.
--

DELIMITER $$

-- ----------------------------------------------------------------------
-- The first layer of a scan: one row per experiment, with the number of
-- records hanging off it.  The counts let a tree show which experiments
-- are worth expanding without reading any of their children, and none of
-- this touches a data blob.
--
-- Each count is the number of rows the matching detail procedure returns
-- for the same caller and p_ID: rawCount and editCount those of
-- get_rawData_by_experiment and get_editedData_by_experiment, modelCount
-- and noiseCount those of get_model_desc_by_experiment and
-- get_noise_desc_by_experiment, which list only models (and noise fitted
-- with models) that have a modelPerson row for the investigator.  Counting
-- every model under the experiment instead made a tree's counts change
-- once the experiment was loaded.  Noise is counted with the experiment of
-- its model, as it is listed, not of the edit it was computed from.
--
-- experimentPerson is tested with EXISTS, not joined, so an experiment
-- linked to several people is still one row when an admin passes p_ID = 0.
--
-- The counts are correlated subqueries on purpose.  Each one is a handful
-- of index lookups for its experiment.  On MySQL 8.0, per-table derived
-- tables grouped by experiment were no faster, for one investigator or for
-- a whole database (5,000 experiments, 150,000 triples: 1.21 s against
-- 1.18 s).  A single join of every table counted with COUNT(DISTINCT) was
-- faster on that evenly spread test data, but it multiplies an edit's
-- models by its noise records, and Monte Carlo fits put hundreds of each on
-- one edit.
-- ----------------------------------------------------------------------
DROP PROCEDURE IF EXISTS get_experiment_summary$$
CREATE PROCEDURE get_experiment_summary ( p_personGUID CHAR(36),
                                          p_password   VARCHAR(80),
                                          p_ID         INT )
  READS SQL DATA

BEGIN
  DECLARE l_ID      INT     DEFAULT 0;
  DECLARE l_allowed TINYINT DEFAULT 0;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  IF ( verify_userlevel( p_personGUID, p_password, @US3_ADMIN ) = @OK ) THEN
    -- This is an admin; p_ID of 0 means every experiment in the database
    SET l_ID            = p_ID;
    SET l_allowed       = 1;
    SET @US3_LAST_ERRNO = @OK;
    SET @US3_LAST_ERROR = '';

  ELSEIF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
    IF ( ( p_ID != 0 ) AND ( p_ID != @US3_ID ) ) THEN
      -- Uh oh, can't do that
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view this experiment';

    ELSE
      -- Ok, user wants his own experiments
      SET l_ID      = @US3_ID;
      SET l_allowed = 1;

    END IF;

  END IF;

  IF ( l_allowed = 0 ) THEN
    -- Not a valid user, or not permitted; check_user or the branch above
    -- has already recorded why
    IF ( @US3_LAST_ERRNO = @OK ) THEN
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view this experiment';
    END IF;

    SELECT @US3_LAST_ERRNO AS status;

  ELSE
    SELECT @OK AS status;

    SELECT   e.experimentID,
             e.experimentGUID,
             e.runID,
             e.type,
             e.runType,
             e.label,
             e.projectID,
             pr.projectGUID,
             pr.description                              AS projectDescription,
             timestamp2UTC( e.dateUpdated )              AS UTC_dateUpdated,
             ( SELECT COUNT(*)
               FROM   rawData r
               WHERE  r.experimentID = e.experimentID )  AS rawCount,
             ( SELECT COUNT(*)
               FROM   editedData d, rawData r2
               WHERE  d.rawDataID     = r2.rawDataID
               AND    r2.experimentID = e.experimentID ) AS editCount,
             ( SELECT COUNT(*)
               FROM   model m, editedData d2, rawData r3, modelPerson mp
               WHERE  m.editedDataID  = d2.editedDataID
               AND    d2.rawDataID    = r3.rawDataID
               AND    r3.experimentID = e.experimentID
               AND    mp.modelID      = m.modelID
               AND    ( l_ID = 0 OR mp.personID = l_ID ) ) AS modelCount,
             ( SELECT COUNT(*)
               FROM   noise n, model m2, editedData d3, rawData r4,
                      modelPerson mp2
               WHERE  n.modelID       = m2.modelID
               AND    m2.editedDataID = d3.editedDataID
               AND    d3.rawDataID    = r4.rawDataID
               AND    r4.experimentID = e.experimentID
               AND    mp2.modelID     = m2.modelID
               AND    ( l_ID = 0 OR mp2.personID = l_ID ) ) AS noiseCount
    FROM     experiment e
             LEFT JOIN project pr ON e.projectID = pr.projectID
    WHERE    EXISTS ( SELECT 1
                      FROM   experimentPerson p
                      WHERE  p.experimentID = e.experimentID
                      AND    ( l_ID = 0 OR p.personID = l_ID ) )
    ORDER BY e.runID;

  END IF;

END$$

-- ----------------------------------------------------------------------
-- Every rawData record of one experiment, with the same columns
-- get_rawData returns for a single record.  The checksum is what tells a
-- caller whether the database copy and a local file still agree, so it is
-- computed here; that means this reads the experiment's data blobs, and it
-- is why a scan only asks for it one experiment at a time.
--
-- An experiment without raw data answers NOROWS; see the file header.
-- ----------------------------------------------------------------------
DROP PROCEDURE IF EXISTS get_rawData_by_experiment$$
CREATE PROCEDURE get_rawData_by_experiment ( p_personGUID   CHAR(36),
                                             p_password     VARCHAR(80),
                                             p_experimentID INT )
  READS SQL DATA

BEGIN
  DECLARE count_rawData INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  -- verify_experiment_permission() matches the caller against @US3_ID, which
  -- is only set once the user has been verified in this connection, so that
  -- happens first here rather than being assumed
  IF ( verify_user( p_personGUID, p_password ) != @OK ) THEN
    SELECT @US3_LAST_ERRNO AS status;

  ELSEIF ( verify_experiment_permission( p_personGUID, p_password, p_experimentID ) != @OK ) THEN
    SELECT @US3_LAST_ERRNO AS status;

  ELSE
    SELECT COUNT(*)
    INTO   count_rawData
    FROM   rawData
    WHERE  experimentID = p_experimentID;

    IF ( count_rawData = 0 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';

      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;

      SELECT   rawDataID, rawDataGUID, label, filename, comment,
               experimentID, solutionID, channelID,
               timestamp2UTC( lastUpdated ) AS UTC_lastUpdated,
               MD5( data ) AS checksum, LENGTH( data ) AS size
      FROM     rawData
      WHERE    experimentID = p_experimentID
      ORDER BY filename;

    END IF;

  END IF;

END$$

-- ----------------------------------------------------------------------
-- Every editedData record of one experiment, whichever triple it belongs
-- to.  rawDataGUID comes along so a caller can attach each edit to its
-- triple without a second query.
--
-- An experiment without edits answers NOROWS; see the file header.
-- ----------------------------------------------------------------------
DROP PROCEDURE IF EXISTS get_editedData_by_experiment$$
CREATE PROCEDURE get_editedData_by_experiment ( p_personGUID   CHAR(36),
                                                p_password     VARCHAR(80),
                                                p_experimentID INT )
  READS SQL DATA

BEGIN
  DECLARE count_editedData INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  -- See the note in get_rawData_by_experiment about @US3_ID
  IF ( verify_user( p_personGUID, p_password ) != @OK ) THEN
    SELECT @US3_LAST_ERRNO AS status;

  ELSEIF ( verify_experiment_permission( p_personGUID, p_password, p_experimentID ) != @OK ) THEN
    SELECT @US3_LAST_ERRNO AS status;

  ELSE
    SELECT COUNT(*)
    INTO   count_editedData
    FROM   editedData d, rawData r
    WHERE  d.rawDataID    = r.rawDataID
    AND    r.experimentID = p_experimentID;

    IF ( count_editedData = 0 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';

      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;

      SELECT   d.editedDataID, d.rawDataID, r.rawDataGUID, d.editGUID,
               d.label, d.filename, d.comment,
               timestamp2UTC( d.lastUpdated ) AS UTC_lastUpdated,
               MD5( d.data ) AS checksum, LENGTH( d.data ) AS size
      FROM     editedData d, rawData r
      WHERE    d.rawDataID    = r.rawDataID
      AND      r.experimentID = p_experimentID
      ORDER BY d.filename;

    END IF;

  END IF;

END$$

-- ----------------------------------------------------------------------
-- Every model fitted to any edit of one experiment.  The columns are the
-- ones get_model_desc_by_editID returns, so a caller can read either with
-- the same code.
--
-- modelPerson's primary key is modelID, so joining it cannot repeat a
-- model, whatever p_ID is.  No models answers OK with an empty data set;
-- see the file header.
-- ----------------------------------------------------------------------
DROP PROCEDURE IF EXISTS get_model_desc_by_experiment$$
CREATE PROCEDURE get_model_desc_by_experiment ( p_personGUID   CHAR(36),
                                                p_password     VARCHAR(80),
                                                p_ID           INT,
                                                p_experimentID INT )
  READS SQL DATA

BEGIN
  DECLARE l_ID INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  -- See the note in get_rawData_by_experiment about @US3_ID
  IF ( verify_user( p_personGUID, p_password ) != @OK ) THEN
    SELECT @US3_LAST_ERRNO AS status;

  ELSEIF ( verify_experiment_permission( p_personGUID, p_password, p_experimentID ) != @OK ) THEN
    SELECT @US3_LAST_ERRNO AS status;

  ELSE
    IF ( verify_userlevel( p_personGUID, p_password, @US3_ADMIN ) = @OK ) THEN
      SET l_ID = p_ID;

    ELSE
      SET l_ID = @US3_ID;

    END IF;

    SET @US3_LAST_ERRNO = @OK;
    SET @US3_LAST_ERROR = '';

    SELECT @OK AS status;

    SELECT   m.modelID, m.modelGUID, m.description, m.variance, m.meniscus,
             d.editGUID, m.editedDataID,
             timestamp2UTC( m.lastUpdated ) AS UTC_lastUpdated,
             MD5( m.xml ) AS checksum, LENGTH( m.xml ) AS size
    FROM     model m
             JOIN editedData d   ON m.editedDataID = d.editedDataID
             JOIN rawData    r   ON d.rawDataID    = r.rawDataID
             JOIN modelPerson mp ON mp.modelID     = m.modelID
    WHERE    r.experimentID = p_experimentID
    AND      ( l_ID = 0 OR mp.personID = l_ID )
    ORDER BY m.modelID DESC;

  END IF;

END$$

-- ----------------------------------------------------------------------
-- Every noise record fitted with a model of one experiment -- that is,
-- with a model get_model_desc_by_experiment lists for the same caller and
-- p_ID.  The noise is in the model's experiment even when the edit it was
-- computed from (noise.editedDataID, the third column) is in another, as
-- with a global fit; noise of a model on the UNASSIGNED edit is in no
-- experiment.  See "Which experiment a record is in" in the file header.
-- The columns are the ones get_noise_desc_by_editID returns.
--
-- A noise record is the investigator's when the model it was fitted with
-- (noise.modelID) has a modelPerson row for them.  No noise answers OK
-- with an empty data set; see the file header.
-- ----------------------------------------------------------------------
DROP PROCEDURE IF EXISTS get_noise_desc_by_experiment$$
CREATE PROCEDURE get_noise_desc_by_experiment ( p_personGUID   CHAR(36),
                                                p_password     VARCHAR(80),
                                                p_ID           INT,
                                                p_experimentID INT )
  READS SQL DATA

BEGIN
  DECLARE l_ID INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  -- See the note in get_rawData_by_experiment about @US3_ID
  IF ( verify_user( p_personGUID, p_password ) != @OK ) THEN
    SELECT @US3_LAST_ERRNO AS status;

  ELSEIF ( verify_experiment_permission( p_personGUID, p_password, p_experimentID ) != @OK ) THEN
    SELECT @US3_LAST_ERRNO AS status;

  ELSE
    IF ( verify_userlevel( p_personGUID, p_password, @US3_ADMIN ) = @OK ) THEN
      SET l_ID = p_ID;

    ELSE
      SET l_ID = @US3_ID;

    END IF;

    SET @US3_LAST_ERRNO = @OK;
    SET @US3_LAST_ERROR = '';

    SELECT @OK AS status;

    SELECT   n.noiseID, n.noiseGUID, n.editedDataID, n.modelID, n.noiseType,
             n.modelGUID,
             timestamp2UTC( n.timeEntered ) AS UTC_timeEntered,
             MD5( n.xml ) AS checksum, LENGTH( n.xml ) AS size, n.description
    FROM     noise n
             JOIN model      m   ON n.modelID      = m.modelID
             JOIN editedData d   ON m.editedDataID = d.editedDataID
             JOIN rawData    r   ON d.rawDataID    = r.rawDataID
             JOIN modelPerson mp ON mp.modelID     = m.modelID
    WHERE    r.experimentID = p_experimentID
    AND      ( l_ID = 0 OR mp.personID = l_ID )
    ORDER BY n.timeEntered DESC;

  END IF;

END$$

-- ----------------------------------------------------------------------
-- Every rawData record the investigator can see, with the experiment it
-- belongs to.  This is the bulk form of get_rawData_by_experiment: one
-- query lists a whole store instead of one per experiment.
--
-- It deliberately does NOT hash the data blobs.  MD5( data ) means reading
-- every raw-data blob in the store, which on a real collection is seconds
-- of server time and by far the most expensive part of a scan, while all
-- it answers is whether a record that also exists on local disk still
-- matches.  A scan therefore lists with this and asks
-- get_rawData_by_experiment for the checksums of the one experiment it is
-- actually comparing.
--
-- experimentPerson is tested with EXISTS rather than joined, so that an
-- experiment linked to more than one person -- or to the same person
-- twice -- does not list its records more than once.
-- ----------------------------------------------------------------------
DROP PROCEDURE IF EXISTS get_rawData_by_person$$
CREATE PROCEDURE get_rawData_by_person ( p_personGUID CHAR(36),
                                         p_password   VARCHAR(80),
                                         p_ID         INT )
  READS SQL DATA

BEGIN
  DECLARE l_ID      INT     DEFAULT 0;
  DECLARE l_allowed TINYINT DEFAULT 0;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  IF ( verify_userlevel( p_personGUID, p_password, @US3_ADMIN ) = @OK ) THEN
    -- This is an admin; p_ID of 0 means every experiment in the database
    SET l_ID            = p_ID;
    SET l_allowed       = 1;
    SET @US3_LAST_ERRNO = @OK;
    SET @US3_LAST_ERROR = '';

  ELSEIF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
    IF ( ( p_ID != 0 ) AND ( p_ID != @US3_ID ) ) THEN
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view this data';

    ELSE
      SET l_ID      = @US3_ID;
      SET l_allowed = 1;

    END IF;

  END IF;

  IF ( l_allowed = 0 ) THEN
    IF ( @US3_LAST_ERRNO = @OK ) THEN
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view this data';
    END IF;

    SELECT @US3_LAST_ERRNO AS status;

  ELSE
    SELECT @OK AS status;

    -- The column layout is the one get_rawData_by_experiment returns, so a
    -- caller reads either with the same code; checksum and size are null
    -- because nothing was hashed
    SELECT   r.rawDataID, r.rawDataGUID, r.label, r.filename, r.comment,
             r.experimentID, r.solutionID, r.channelID,
             timestamp2UTC( r.lastUpdated ) AS UTC_lastUpdated,
             NULL AS checksum, NULL AS size
    FROM     rawData r
    WHERE    EXISTS ( SELECT 1
                      FROM   experimentPerson p
                      WHERE  p.experimentID = r.experimentID
                      AND    ( l_ID = 0 OR p.personID = l_ID ) )
    ORDER BY r.experimentID, r.filename;

  END IF;

END$$

-- ----------------------------------------------------------------------
-- Every editedData record the investigator can see, with the GUID of the
-- triple it belongs to and the experiment that triple is in.  The bulk
-- form of get_editedData_by_experiment, and it does not hash the blobs
-- either; see the notes on get_rawData_by_person, which also apply to how
-- experimentPerson is tested.
-- ----------------------------------------------------------------------
DROP PROCEDURE IF EXISTS get_editedData_by_person$$
CREATE PROCEDURE get_editedData_by_person ( p_personGUID CHAR(36),
                                            p_password   VARCHAR(80),
                                            p_ID         INT )
  READS SQL DATA

BEGIN
  DECLARE l_ID      INT     DEFAULT 0;
  DECLARE l_allowed TINYINT DEFAULT 0;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  IF ( verify_userlevel( p_personGUID, p_password, @US3_ADMIN ) = @OK ) THEN
    SET l_ID            = p_ID;
    SET l_allowed       = 1;
    SET @US3_LAST_ERRNO = @OK;
    SET @US3_LAST_ERROR = '';

  ELSEIF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
    IF ( ( p_ID != 0 ) AND ( p_ID != @US3_ID ) ) THEN
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view this data';

    ELSE
      SET l_ID      = @US3_ID;
      SET l_allowed = 1;

    END IF;

  END IF;

  IF ( l_allowed = 0 ) THEN
    IF ( @US3_LAST_ERRNO = @OK ) THEN
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view this data';
    END IF;

    SELECT @US3_LAST_ERRNO AS status;

  ELSE
    SELECT @OK AS status;

    SELECT   d.editedDataID, d.rawDataID, r.rawDataGUID, d.editGUID,
             d.label, d.filename, d.comment,
             timestamp2UTC( d.lastUpdated ) AS UTC_lastUpdated,
             NULL AS checksum, NULL AS size
    FROM     editedData d
             JOIN rawData r ON d.rawDataID = r.rawDataID
    WHERE    EXISTS ( SELECT 1
                      FROM   experimentPerson p
                      WHERE  p.experimentID = r.experimentID
                      AND    ( l_ID = 0 OR p.personID = l_ID ) )
    ORDER BY r.experimentID, d.filename;

  END IF;

END$$

DELIMITER ;
