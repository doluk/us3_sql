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

DELIMITER $$

-- ----------------------------------------------------------------------
-- The first layer of a scan: one row per experiment, with the number of
-- records hanging off it.  The counts let a tree show which experiments
-- are worth expanding without reading any of their children, and none of
-- this touches a data blob.
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
    IF ( ( p_ID != 0 ) && ( p_ID != @US3_ID ) ) THEN
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
               FROM   model m, editedData d2, rawData r3
               WHERE  m.editedDataID  = d2.editedDataID
               AND    d2.rawDataID    = r3.rawDataID
               AND    r3.experimentID = e.experimentID ) AS modelCount,
             ( SELECT COUNT(*)
               FROM   noise n, editedData d3, rawData r4
               WHERE  n.editedDataID  = d3.editedDataID
               AND    d3.rawDataID    = r4.rawDataID
               AND    r4.experimentID = e.experimentID ) AS noiseCount
    FROM     experiment e
             JOIN experimentPerson p ON e.experimentID = p.experimentID
             LEFT JOIN project pr    ON e.projectID    = pr.projectID
    WHERE    ( l_ID = 0 OR p.personID = l_ID )
    ORDER BY e.runID;

  END IF;

END$$

-- ----------------------------------------------------------------------
-- Every rawData record of one experiment, with the same columns
-- get_rawData returns for a single record.  The checksum is what tells a
-- caller whether the database copy and a local file still agree, so it is
-- computed here; that means this reads the experiment's data blobs, and it
-- is why a scan only asks for it one experiment at a time.
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

  SELECT COUNT(*)
  INTO   count_rawData
  FROM   rawData
  WHERE  experimentID = p_experimentID;

  -- verify_experiment_permission() matches the caller against @US3_ID, which
  -- is only set once the user has been verified in this connection, so that
  -- happens first here rather than being assumed
  IF ( verify_user( p_personGUID, p_password ) != @OK ) THEN
    SELECT @US3_LAST_ERRNO AS status;

  ELSEIF ( verify_experiment_permission( p_personGUID, p_password, p_experimentID ) = @OK ) THEN
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

  ELSE
    SELECT @US3_LAST_ERRNO AS status;

  END IF;

END$$

-- ----------------------------------------------------------------------
-- Every editedData record of one experiment, whichever triple it belongs
-- to.  rawDataGUID comes along so a caller can attach each edit to its
-- triple without a second query.
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

  SELECT COUNT(*)
  INTO   count_editedData
  FROM   editedData d, rawData r
  WHERE  d.rawDataID    = r.rawDataID
  AND    r.experimentID = p_experimentID;

  -- See the note in get_rawData_by_experiment about @US3_ID
  IF ( verify_user( p_personGUID, p_password ) != @OK ) THEN
    SELECT @US3_LAST_ERRNO AS status;

  ELSEIF ( verify_experiment_permission( p_personGUID, p_password, p_experimentID ) = @OK ) THEN
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

  ELSE
    SELECT @US3_LAST_ERRNO AS status;

  END IF;

END$$

-- ----------------------------------------------------------------------
-- Every model fitted to any edit of one experiment.  The columns are the
-- ones get_model_desc_by_editID returns, so a caller can read either with
-- the same code.
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
-- Every noise record belonging to any edit of one experiment.  The columns
-- are the ones get_noise_desc_by_editID returns.
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
             JOIN editedData d   ON n.editedDataID = d.editedDataID
             JOIN rawData    r   ON d.rawDataID    = r.rawDataID
             JOIN modelPerson mp ON mp.modelID     = n.modelID
    WHERE    r.experimentID = p_experimentID
    AND      ( l_ID = 0 OR mp.personID = l_ID )
    ORDER BY n.timeEntered DESC;

  END IF;

END$$

DELIMITER ;
