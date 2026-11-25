--
-- us3_expdata_procs.sql
--
-- Script to set up the MySQL stored procedures for the US3 system
--   These are procedures related to the experiment data
-- Run as us3admin
--

DELIMITER $$

-- A series of procedures dealing with rawData

-- Get a list of rawDataID's that correspond with this experiment
DROP PROCEDURE IF EXISTS get_rawDataIDs$$
CREATE PROCEDURE get_rawDataIDs ( p_personGUID   CHAR(36),
                                  p_password     VARCHAR(80),
                                  p_experimentID INT )
  READS SQL DATA

BEGIN
  DECLARE count_rawData INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  SELECT     COUNT(*)
  INTO       count_rawData
  FROM       rawData
  WHERE      experimentID = p_experimentID;

  IF ( verify_experiment_permission( p_personGUID, p_password, p_experimentID ) = @OK ) THEN
    IF ( count_rawData = 0 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';

      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;

      SELECT   rawDataID, label, filename
      FROM     rawData
      WHERE    experimentID = p_experimentID;

    END IF;

  ELSE
    SELECT @US3_LAST_ERRNO AS status;

  END IF;

END$$

-- Translate a rawDataGUID into a rawDataID
DROP PROCEDURE IF EXISTS get_rawDataID_from_GUID$$
CREATE PROCEDURE get_rawDataID_from_GUID ( p_personGUID   CHAR(36),
                                           p_password     VARCHAR(80),
                                           p_rawDataGUID  CHAR(36) )
  READS SQL DATA

BEGIN
  DECLARE count_rawData  INT;
  DECLARE l_rawDataID    INT;
  DECLARE l_experimentID INT;
  DECLARE l_solutionID   INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  SELECT     COUNT(*)
  INTO       count_rawData
  FROM       rawData
  WHERE      rawDataGUID = p_rawDataGUID;

  IF ( count_rawData = 0 ) THEN
    SET @US3_LAST_ERRNO = @NOROWS;
    SET @US3_LAST_ERROR = 'MySQL: no rows returned';

    SELECT @US3_LAST_ERRNO AS status;

  ELSE
    -- Let's get both the rawDataID and the experimentID so we can verify permission
    SELECT rawDataID, experimentID, solutionID
    INTO   l_rawDataID, l_experimentID, l_solutionID
    FROM   rawData
    WHERE  rawDataGUID = p_rawDataGUID
    LIMIT  1;                           -- should be only 1

    IF ( verify_experiment_permission( p_personGUID, p_password, l_experimentID ) = @OK ) THEN
      SELECT @OK AS status;

      SELECT l_rawDataID AS rawDataID, 
             l_experimentID AS experimentID,
             l_solutionID AS solutionID;

    ELSE
      SELECT @US3_LAST_ERRNO AS status;

    END IF;

  END IF;

END$$

-- Returns the count of raw data entries associated with an
-- experiment; should be the same as the number of triples,
-- or c/c/w combinations
DROP FUNCTION IF EXISTS count_rawData_by_experiment$$
CREATE FUNCTION count_rawData_by_experiment( p_personGUID   CHAR(36),
                                             p_password     VARCHAR(80),
                                             p_experimentID INT )
  RETURNS INT
  READS SQL DATA

BEGIN
  
  DECLARE count_rawData INT;

  CALL config();
  SET count_rawData = 0;

  IF ( verify_experiment_permission( p_personGUID, p_password, p_experimentID ) = @OK ) THEN
    -- This is either an admin, or a person inquiring about his own experiment
    SELECT COUNT(*)
    INTO   count_rawData
    FROM   rawData
    WHERE  experimentID = p_experimentID;

  END IF;

  RETURN( count_rawData );

END$$

-- Returns the count of raw data entries associated with a user
DROP FUNCTION IF EXISTS count_rawData$$
CREATE FUNCTION count_rawData( p_personGUID   CHAR(36),
                               p_password     VARCHAR(80),
                               p_ID           INT )
  RETURNS INT
  READS SQL DATA

BEGIN
  
  DECLARE count_rawData INT;

  CALL config();
  SET count_rawData = 0;

  IF ( verify_userlevel( p_personGUID, p_password, @US3_ADMIN ) = @OK ) THEN
    -- This is an admin; he can get more info
    IF ( p_ID > 0 ) THEN
      SELECT     COUNT(*)
      INTO       count_rawData
      FROM       rawData, experiment, experimentPerson
      WHERE      experimentPerson.personID = p_ID
      AND        experiment.experimentID = experimentPerson.experimentID
      AND        rawData.experimentID = experiment.experimentID;

    ELSE
      SELECT     COUNT(*)
      INTO       count_rawData
      FROM       rawData;

    END IF;

  ELSEIF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
    IF ( (p_ID != 0) && (p_ID != @US3_ID) ) THEN
      -- Uh oh, can't do that
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view those experiments';
     
    ELSE
      -- This person is asking about his own experiments
      -- Ignore p_ID and return user's own
      SELECT     COUNT(*)
      INTO       count_rawData
      FROM       rawData, experiment, experimentPerson
      WHERE      experimentPerson.personID = @US3_ID
      AND        experiment.experimentID = experimentPerson.experimentID
      AND        rawData.experimentID = experiment.experimentID;

    END IF;
    
  END IF;

  RETURN( count_rawData );

END$$

-- Get a list of all rawDataID's that belong to this user
DROP PROCEDURE IF EXISTS all_rawDataIDs$$
CREATE PROCEDURE all_rawDataIDs ( p_personGUID   CHAR(36),
                                  p_password     VARCHAR(80),
                                  p_ID           INT )
  READS SQL DATA

BEGIN
  DECLARE count_rawData INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  IF ( verify_userlevel( p_personGUID, p_password, @US3_ADMIN ) = @OK ) THEN
    -- This is an admin; he can get more info
    IF ( count_rawData( p_personGUID, p_password, p_ID ) < 1 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';
   
      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;
  
      IF ( p_ID > 0 ) THEN
        SELECT     rawDataID, rawData.label, rawData.filename,
                   rawData.experimentID, rawData.solutionID, 
                   timestamp2UTC( rawData.lastUpdated) AS UTC_lastUpdated, 
                   MD5( rawData.data ) AS checksum, LENGTH( rawData.data ) AS size,
                   experimentPerson.personID,
                   rawDataGUID, rawData.comment, experiment.experimentGUID
        FROM       rawData, experiment, experimentPerson
        WHERE      experimentPerson.personID = p_ID
        AND        experiment.experimentID = experimentPerson.experimentID
        AND        rawData.experimentID = experiment.experimentID
        ORDER BY   rawData.lastUpdated DESC;

      ELSE
        SELECT     rawDataID, rawData.label, rawData.filename,
                   rawData.experimentID, rawData.solutionID,
                   timestamp2UTC( rawData.lastUpdated) AS UTC_lastUpdated, 
                   MD5( rawData.data ) AS checksum, LENGTH( rawData.data ) AS size,
                   experimentPerson.personID,
                   rawDataGUID, rawData.comment, experiment.experimentGUID
        FROM       rawData, experiment, experimentPerson
        WHERE      experiment.experimentID = experimentPerson.experimentID
        AND        rawData.experimentID = experiment.experimentID
        ORDER BY   rawData.lastUpdated DESC;

      END IF;

    END IF;

  ELSEIF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
    IF ( (p_ID != 0) && (p_ID != @US3_ID) ) THEN
      -- Uh oh, can't do that
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view this experiment';
     
      SELECT @US3_LAST_ERRNO AS status;

    ELSEIF ( count_experiments( p_personGUID, p_password, @US3_ID ) < 1 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';
   
      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      -- Ok, user wants his own info
      SELECT @OK AS status;

      SELECT     rawDataID, rawData.label, rawData.filename,
                 rawData.experimentID, rawData.solutionID, 
                 timestamp2UTC( rawData.lastUpdated) AS UTC_lastUpdated, 
                 MD5( rawData.data ) AS checksum, LENGTH( rawData.data ) AS size,
                 experimentPerson.personID,
                 rawDataGUID, rawData.comment, experiment.experimentGUID
      FROM       rawData, experiment, experimentPerson
      WHERE      experimentPerson.personID = @US3_ID
      AND        experiment.experimentID = experimentPerson.experimentID
      AND        rawData.experimentID = experiment.experimentID
      ORDER BY   rawData.lastUpdated DESC;

    END IF;

  END IF;

END$$


-- Get rawDataGUID/ID based on filebase and triple combo
DROP PROCEDURE IF EXISTS get_rawDataGUID_from_filename$$
CREATE PROCEDURE get_rawDataGUID_from_filename ( p_personGUID       CHAR(36),
                                    	       p_password           VARCHAR(80),
                                    	       p_filebase_template  VARCHAR(200),
					       p_triple_template    VARCHAR(10))

  READS SQL DATA

BEGIN
  DECLARE template VARCHAR(250);

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
  SET p_filebase_template  = TRIM( p_filebase_template );
  SET p_triple_template    = TRIM( p_triple_template );

  IF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
     SELECT @OK AS status;
     SET template = CONCAT('%', p_filebase_template, '%', p_triple_template, '%');
     
     SELECT   rawDataID, rawDataGUID
     FROM     rawData
     WHERE    filename LIKE template;
        
  END IF;
END$$


-- Get a list of rawData descriptions that belong to this user (no cksum,size)
DROP PROCEDURE IF EXISTS get_rawData_desc$$
CREATE PROCEDURE get_rawData_desc ( p_personGUID   CHAR(36),
                                    p_password     VARCHAR(80),
                                    p_ID           INT )
  READS SQL DATA

BEGIN
  DECLARE count_rawData INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  IF ( verify_userlevel( p_personGUID, p_password, @US3_ADMIN ) = @OK ) THEN
    -- This is an admin; he can get more info
    IF ( count_rawData( p_personGUID, p_password, p_ID ) < 1 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';
   
      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;
  
      IF ( p_ID > 0 ) THEN
        SELECT     rawDataID, rawData.label, rawData.filename,
                   rawData.experimentID, rawData.solutionID, 
                   timestamp2UTC( rawData.lastUpdated) AS UTC_lastUpdated, 
                   experimentPerson.personID,
                   rawDataGUID, rawData.comment, experiment.experimentGUID
        FROM       rawData, experiment, experimentPerson
        WHERE      experimentPerson.personID = p_ID
        AND        experiment.experimentID = experimentPerson.experimentID
        AND        rawData.experimentID = experiment.experimentID
        ORDER BY   rawData.lastUpdated DESC;

      ELSE
        SELECT     rawDataID, rawData.label, rawData.filename,
                   rawData.experimentID, rawData.solutionID,
                   timestamp2UTC( rawData.lastUpdated) AS UTC_lastUpdated, 
                   experimentPerson.personID,
                   rawDataGUID, rawData.comment, experiment.experimentGUID
        FROM       rawData, experiment, experimentPerson
        WHERE      experiment.experimentID = experimentPerson.experimentID
        AND        rawData.experimentID = experiment.experimentID
        ORDER BY   rawData.lastUpdated DESC;

      END IF;

    END IF;

  ELSEIF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
    IF ( (p_ID != 0) && (p_ID != @US3_ID) ) THEN
      -- Uh oh, can't do that
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view this experiment';
     
      SELECT @US3_LAST_ERRNO AS status;

    ELSEIF ( count_experiments( p_personGUID, p_password, @US3_ID ) < 1 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';
   
      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      -- Ok, user wants his own info
      SELECT @OK AS status;

      SELECT     rawDataID, rawData.label, rawData.filename,
                 rawData.experimentID, rawData.solutionID, 
                 timestamp2UTC( rawData.lastUpdated) AS UTC_lastUpdated, 
                 experimentPerson.personID,
                 rawDataGUID, rawData.comment, experiment.experimentGUID
      FROM       rawData, experiment, experimentPerson
      WHERE      experimentPerson.personID = @US3_ID
      AND        experiment.experimentID = experimentPerson.experimentID
      AND        rawData.experimentID = experiment.experimentID
      ORDER BY   rawData.lastUpdated DESC;

    END IF;

  END IF;

END$$

-- Get a list of rawData descriptions for a specified runID (no cksum,size)
DROP PROCEDURE IF EXISTS get_raw_desc_by_runID$$
CREATE PROCEDURE get_raw_desc_by_runID ( p_personGUID   CHAR(36),
                                         p_password     VARCHAR(80),
                                         p_ID           INT,
                                         p_runID        VARCHAR(250) )
  READS SQL DATA

BEGIN

  DECLARE count_rawData INT;
  DECLARE run_pattern VARCHAR(254);

  CALL config();
  SET run_pattern = CONCAT( p_runID, '.%' );
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  SELECT     COUNT(*)
  INTO       count_rawData
  FROM       rawData
  WHERE      filename LIKE run_pattern;

  IF ( p_ID <= 0 ) THEN
    -- Gotta have a real ID
    SET @US3_LAST_ERRNO = @EMPTY;
    SET @US3_LAST_ERROR = 'MySQL: The ID cannot be 0';

    SELECT @US3_LAST_ERRNO AS status;

  ELSEIF ( verify_userlevel( p_personGUID, p_password, @US3_ADMIN ) = @OK ) THEN
    -- This is an admin; he can get more info
    IF ( count_rawData < 1 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';
   
      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;
  
      SELECT     rawDataID, rawData.label, rawData.filename,
                 rawData.experimentID, rawData.solutionID, 
                 timestamp2UTC( rawData.lastUpdated) AS UTC_lastUpdated, 
                 experimentPerson.personID,
                 rawDataGUID, rawData.comment, experiment.experimentGUID
      FROM       rawData, experiment, experimentPerson
      WHERE      experimentPerson.personID = p_ID
      AND        rawData.filename LIKE run_pattern
      AND        experiment.experimentID = experimentPerson.experimentID
      AND        rawData.experimentID = experiment.experimentID
      ORDER BY   rawData.lastUpdated DESC;

    END IF;

  ELSEIF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
    -- Ok, user wants his own info
    IF ( (p_ID != 0) && (p_ID != @US3_ID ) ) THEN
      -- Uh oh, can't do that
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view this model';
   
      SELECT @US3_LAST_ERRNO AS status;

    ELSEIF ( count_rawData < 1 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';
   
      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;

      SELECT     rawDataID, rawData.label, rawData.filename,
                 rawData.experimentID, rawData.solutionID, 
                 timestamp2UTC( rawData.lastUpdated) AS UTC_lastUpdated, 
                 experimentPerson.personID,
                 rawDataGUID, rawData.comment, experiment.experimentGUID
      FROM       rawData, experiment, experimentPerson
      WHERE      experimentPerson.personID = @US3_ID
      AND        rawData.filename LIKE run_pattern
      AND        experiment.experimentID = experimentPerson.experimentID
      AND        rawData.experimentID = experiment.experimentID
      ORDER BY   rawData.lastUpdated DESC;

    END IF;
  END IF;

END$$

-- INSERTs new rawData information about one c/c/w combination in an experiment
DROP PROCEDURE IF EXISTS new_rawData$$
CREATE PROCEDURE new_rawData ( p_personGUID   CHAR(36),
                               p_password     VARCHAR(80),
                               p_rawDataGUID  CHAR(36),
                               p_label        VARCHAR(80),
                               p_filename     VARCHAR(255),
                               p_comment      TEXT,
                               p_experimentID INT,
                               p_solutionID   INT,
                               p_channelID    INT )
  MODIFIES SQL DATA

BEGIN

  DECLARE null_field    TINYINT DEFAULT 0;
  DECLARE duplicate_key TINYINT DEFAULT 0;

  DECLARE CONTINUE HANDLER FOR 1048
    SET null_field = 1;

  DECLARE CONTINUE HANDLER FOR 1062
    SET duplicate_key = 1;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
  SET @LAST_INSERT_ID = 0;
 
  IF ( verify_experiment_permission( p_personGUID, p_password, p_experimentID ) = @OK ) THEN
 
    -- This is either an admin, or a person inquiring about his own experiment
    INSERT INTO rawData SET
      rawDataGUID   = p_rawDataGUID,    -- this needs to be generated by caller
      label         = p_label,
      filename      = p_filename,
      comment       = p_comment,
      experimentID  = p_experimentID,
      solutionID    = p_solutionID,
      channelID     = p_channelID,
      lastUpdated   = NOW();
   
    IF ( null_field = 1 ) THEN
      SET @US3_LAST_ERRNO = @INSERTNULL;
      SET @US3_LAST_ERROR = "MySQL: Attempt to insert NULL value in the rawData table";

    ELSEIF ( duplicate_key = 1 ) THEN
      SET @US3_LAST_ERRNO = @DUPFIELD;
      SET @US3_LAST_ERROR = CONCAT( "MySQL: The GUID ",
                                    p_rawDataGUID,
                                    " already exists in the rawData table" );
      
    ELSE
      SET @LAST_INSERT_ID  = LAST_INSERT_ID();

    END IF;
   
   END IF;

  SELECT @US3_LAST_ERRNO AS status;

END$$

-- SELECTs rawData information about one c/c/w combination in an experiment
DROP PROCEDURE IF EXISTS get_rawData$$
CREATE PROCEDURE get_rawData ( p_personGUID   CHAR(36),
                               p_password     VARCHAR(80),
                               p_rawDataID    INT )
  READS SQL DATA

BEGIN

  DECLARE l_experimentID  INT;
  DECLARE count_rawData   INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
 
  -- Do a preliminary call to check permissions
  SELECT experimentID
  INTO   l_experimentID
  FROM   rawData
  WHERE  rawDataID = p_rawDataID
  LIMIT  1;                         -- there could be multiple

  SELECT     COUNT(*)
  INTO       count_rawData
  FROM       rawData
  WHERE      rawDataID = p_rawDataID;

  IF ( count_rawData = 0 ) THEN
    SET @US3_LAST_ERRNO = @NOROWS;
    SET @US3_LAST_ERROR = 'MySQL: no rows returned';

    SELECT @US3_LAST_ERRNO AS status;

  ELSEIF ( verify_experiment_permission( p_personGUID, p_password, l_experimentID ) = @OK ) THEN
    -- This is either an admin, or a person inquiring about his own experiment
    SELECT @OK as status;

    SELECT  rawDataGUID, label, filename, comment, experimentID, solutionID, channelID, 
            timestamp2UTC( lastUpdated ) AS UTC_lastUpdated, 
            MD5( data ) AS checksum, LENGTH( data ) AS size
    FROM    rawData
    WHERE   rawDataID = p_rawDataID;

  ELSE
    SELECT @US3_LAST_ERRNO AS status;

  END IF;

END$$

-- DELETEs all rawData related to an experiment, plus information in related tables
-- Most likely used if you're updating an experiment 
DROP PROCEDURE IF EXISTS delete_rawData$$
CREATE PROCEDURE delete_rawData ( p_personGUID   CHAR(36),
                                  p_password     VARCHAR(80),
                                  p_experimentID INT )
  MODIFIES SQL DATA

BEGIN
  -- Set up to delete any number of reports with this experimentID
  DECLARE l_last_row INT DEFAULT 0;
  DECLARE l_reportID INT;
  DECLARE get_reports CURSOR FOR
    SELECT reportID
    FROM   report
    WHERE  experimentID = p_experimentID;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET l_last_row = 1;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  IF ( verify_experiment_permission( p_personGUID, p_password, p_experimentID ) = @OK ) THEN
    -- Get all associated reportID's and delete them
    OPEN get_reports;
    rpt_cursor: LOOP
      FETCH get_reports INTO l_reportID;
      IF ( l_last_row = 1 ) THEN
         LEAVE rpt_cursor;
      END IF;

      -- Not the end of the data, so let's delete this one
      CALL delete_report( p_personGUID, p_password, l_reportID );

    END LOOP rpt_cursor;
    CLOSE get_reports;

    -- Make sure records match if they have related tables or not
    -- Have to do it in a couple of stages because of the constraints
    DELETE      noise
    FROM        rawData
    LEFT JOIN   editedData  ON ( editedData.rawDataID = rawData.rawDataID )
    LEFT JOIN   model       ON ( model.editedDataID   = editedData.editedDataID )
    LEFT JOIN   noise       ON ( noise.modelID        = model.modelID )
    WHERE       rawData.experimentID = p_experimentID;

    DELETE      model, modelPerson
    FROM        rawData
    LEFT JOIN   editedData  ON ( editedData.rawDataID = rawData.rawDataID )
    LEFT JOIN   model       ON ( model.editedDataID   = editedData.editedDataID )
    LEFT JOIN   modelPerson ON ( modelPerson.modelID  = model.modelID )
    WHERE       rawData.experimentID = p_experimentID;

    DELETE      editedData
    FROM        rawData
    LEFT JOIN   editedData  ON ( editedData.rawDataID = rawData.rawDataID )
    WHERE       rawData.experimentID = p_experimentID;

    DELETE FROM rawData
    WHERE       experimentID = p_experimentID;

  END IF;

  SELECT @US3_LAST_ERRNO AS status;

END$$

-- UPDATEs a rawData record with the auc data
DROP PROCEDURE IF EXISTS upload_aucData$$
CREATE PROCEDURE upload_aucData ( p_personGUID   CHAR(36),
                                  p_password     VARCHAR(80),
                                  p_rawDataID    INT,
                                  p_data         LONGBLOB,
                                  p_checksum     CHAR(33) )
  MODIFIES SQL DATA

BEGIN
  DECLARE l_checksum     CHAR(33);
  DECLARE l_experimentID INT;
  DECLARE not_found      TINYINT DEFAULT 0;

  DECLARE CONTINUE HANDLER FOR NOT FOUND
    SET not_found = 1;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
 
  -- Compare checksum with calculated checksum
  SET l_checksum = MD5( p_data );
  SET @DEBUG = CONCAT( l_checksum , ' ', p_checksum );

  -- Get information we need to verify ownership
  SELECT experimentID
  INTO   l_experimentID
  FROM   rawData
  WHERE  rawDataID = p_rawDataID;

  IF ( l_checksum != p_checksum ) THEN

    -- Checksums don't match; abort
    SET @US3_LAST_ERRNO = @BAD_CHECKSUM;
    SET @US3_LAST_ERROR = "MySQL: Transmission error, bad checksum";

  ELSEIF ( verify_experiment_permission( p_personGUID, p_password, l_experimentID ) = @OK ) THEN
 
    -- This is either an admin, or a person inquiring about his own experiment
    UPDATE rawData SET
      data           = p_data
    WHERE  rawDataID = p_rawDataID;

    IF ( not_found = 1 ) THEN
      SET @US3_LAST_ERRNO = @NO_RAWDATA;
      SET @US3_LAST_ERROR = "MySQL: No raw data with that ID exists";

    END IF;

  END IF;

  SELECT @US3_LAST_ERRNO AS status;

END$$

-- SELECTs a rawData record of auc data previously saved with upload_aucData
DROP PROCEDURE IF EXISTS download_aucData$$
CREATE PROCEDURE download_aucData ( p_personGUID   CHAR(36),
                                    p_password     VARCHAR(80),
                                    p_rawDataID    INT )
  READS SQL DATA

BEGIN
  DECLARE l_count_aucData INT;
  DECLARE l_experimentID  INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
 
  -- Get information to verify that there are records
  SELECT COUNT(*)
  INTO   l_count_aucData
  FROM   rawData
  WHERE  rawDataID = p_rawDataID;

SET @DEBUG = CONCAT('Raw data ID = ', p_rawDataID,
                    'Count = ', l_count_aucData );
  -- Get information we need to verify ownership
  SELECT experimentID
  INTO   l_experimentID
  FROM   rawData
  WHERE  rawDataID = p_rawDataID;

  IF ( l_count_aucData != 1 ) THEN
    -- Probably no rows
    SET @US3_LAST_ERRNO = @NOROWS;
    SET @US3_LAST_ERROR = 'MySQL: no rows exist with that ID (or too many rows)';

    SELECT @NOROWS AS status;
    
  ELSEIF ( verify_experiment_permission( p_personGUID, p_password, l_experimentID ) != @OK ) THEN
 
    -- verify_experiment_permission must have thrown an error, so pass it on
    SELECT @US3_LAST_ERRNO AS status;

  ELSE

    -- This is either an admin, or a person inquiring about his own experiment
    SELECT @OK AS status;

    SELECT data, MD5( data )
    FROM   rawData
    WHERE  rawDataID = p_rawDataID;

  END IF;

END$$

-- A series of procedures dealing with editedData

-- Verifies that the user has permission to view or modify
--  the specified edit profile
DROP FUNCTION IF EXISTS verify_editData_permission$$
CREATE FUNCTION verify_editData_permission( p_personGUID   CHAR(36),
                                            p_password     VARCHAR(80),
                                            p_editedDataID INT )
  RETURNS INT
  READS SQL DATA

BEGIN
  DECLARE count_experiments INT;
  DECLARE status            INT;
  DECLARE l_experimentID    INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  SELECT COUNT(*)
  INTO   count_experiments
  FROM   editedData, rawData
  WHERE  editedDataID = p_editedDataID
  AND    editedData.rawDataID = rawData.rawDataID;
 
  IF ( p_editedDataID = 1 ) THEN
    -- Everybody can use this
    SET status = @OK;
    
  ELSEIF ( count_experiments = 1 ) THEN           -- this is what it should be
    -- Find experimentID so we can check permissions on that
    SELECT experimentID
    INTO   l_experimentID
    FROM   editedData, rawData
    WHERE  editedDataID = p_editedDataID
    AND    editedData.rawDataID = rawData.rawDataID;

    IF ( verify_experiment_permission( p_personGUID, p_password, l_experimentID ) = @OK ) THEN
      SET status = @OK;

    ELSE
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view or modify this experiment';

      SET status = @NOTPERMITTED;

    END IF;

  ELSE
    SET @US3_LAST_ERRNO = @NO_EXPERIMENT;
    SET @US3_LAST_ERROR = 'MySQL: the associated experiment does not exist';

    SET status = @NO_EXPERIMENT;

  END IF;

  RETURN( status );

END$$

-- Get a list of all editedDataID's that belong to this raw data
DROP PROCEDURE IF EXISTS get_editedDataIDs$$
CREATE PROCEDURE get_editedDataIDs ( p_personGUID   CHAR(36),
                                     p_password     VARCHAR(80),
                                     p_rawDataID INT )
  READS SQL DATA

BEGIN
  DECLARE count_editedData INT;
  DECLARE l_experimentID   INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  SELECT     COUNT(*)
  INTO       count_editedData
  FROM       editedData
  WHERE      rawDataID = p_rawDataID;

  -- Get the experimentID so we can verify permission on this data
  SELECT     experimentID
  INTO       l_experimentID
  FROM       rawData
  WHERE      rawDataID = p_rawDataID;

  IF ( verify_experiment_permission( p_personGUID, p_password, l_experimentID ) = @OK ) THEN
    IF ( count_editedData = 0 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';

      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;

      SELECT   editedDataID, label, filename
      FROM     editedData
      WHERE    rawDataID = p_rawDataID;

    END IF;

  ELSE
    SELECT @US3_LAST_ERRNO AS status;

  END IF;

END$$

-- Returns the count of edit profiles associated with a user
DROP FUNCTION IF EXISTS count_editedData$$
CREATE FUNCTION count_editedData( p_personGUID   CHAR(36),
                                  p_password     VARCHAR(80),
                                  p_ID           INT )
  RETURNS INT
  READS SQL DATA

BEGIN
  
  DECLARE count_editedData INT;

  CALL config();
  SET count_editedData = 0;

  IF ( verify_userlevel( p_personGUID, p_password, @US3_ADMIN ) = @OK ) THEN
    -- This is an admin; he can get more info
    IF ( p_ID > 0 ) THEN
      SELECT     COUNT(*)
      INTO       count_editedData
      FROM       editedData, rawData, experiment, experimentPerson
      WHERE      experimentPerson.personID = p_ID
      AND        experiment.experimentID = experimentPerson.experimentID
      AND        rawData.experimentID = experiment.experimentID
      AND        editedData.rawDataID = rawData.rawDataID;

    ELSE
      SELECT     COUNT(*)
      INTO       count_editedData
      FROM       editedData;

    END IF;

  ELSEIF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
    IF ( (p_ID != 0) && (p_ID != @US3_ID) ) THEN
      -- Uh oh, can't do that
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view those experiments';
     
    ELSE
      -- This person is asking about his own experiments
      -- Ignore p_ID and return user's own
      SELECT     COUNT(*)
      INTO       count_editedData
      FROM       editedData, rawData, experiment, experimentPerson
      WHERE      experimentPerson.personID = @US3_ID
      AND        experiment.experimentID = experimentPerson.experimentID
      AND        rawData.experimentID = experiment.experimentID
      AND        editedData.rawDataID = rawData.rawDataID;

    END IF;
    
  END IF;

  RETURN( count_editedData );

END$$

-- Returns the count of edit profiles associated with an
-- raw data set
DROP FUNCTION IF EXISTS count_editedData_by_rawData$$
CREATE FUNCTION count_editedData_by_rawData( p_personGUID   CHAR(36),
                                             p_password     VARCHAR(80),
                                             p_rawDataID    INT )
  RETURNS INT
  READS SQL DATA

BEGIN
  
  DECLARE count_editedData INT;
  DECLARE l_experimentID   INT;

  CALL config();
  SET count_editedData = 0;

  -- Get the experimentID so we can verify permission on this data
  SELECT     experimentID
  INTO       l_experimentID
  FROM       rawData
  WHERE      rawDataID = p_rawDataID;

  IF ( verify_experiment_permission( p_personGUID, p_password, l_experimentID ) = @OK ) THEN
    -- This is either an admin, or a person inquiring about his own experiment
    SELECT COUNT(*)
    INTO   count_editedData
    FROM   editedData
    WHERE  rawDataID = p_rawDataID;

  END IF;

  RETURN( count_editedData );

END$$

-- Get a list of all editDataID's that belong to this user
DROP PROCEDURE IF EXISTS all_editedDataIDs$$
CREATE PROCEDURE all_editedDataIDs ( p_personGUID   CHAR(36),
                                     p_password     VARCHAR(80),
                                     p_ID           INT )
  READS SQL DATA

BEGIN
  DECLARE count_editData INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  IF ( verify_userlevel( p_personGUID, p_password, @US3_ADMIN ) = @OK ) THEN
    -- This is an admin; he can get more info
    IF ( count_editedData( p_personGUID, p_password, p_ID ) < 1 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';
   
      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;
  
      IF ( p_ID > 0 ) THEN
        SELECT     editedDataID, editedData.label, editedData.filename,
                   editedData.rawDataID, rawData.experimentID,
                   timestamp2UTC( editedData.lastUpdated) AS UTC_lastUpdated, 
                   MD5( editedData.data ) AS checksum, LENGTH( editedData.data ) AS size,
                   experiment.type, editedData.editGUID
        FROM       editedData, rawData, experiment, experimentPerson
        WHERE      experimentPerson.personID = p_ID
        AND        experiment.experimentID = experimentPerson.experimentID
        AND        rawData.experimentID = experiment.experimentID
        AND        editedData.rawDataID = rawData.rawDataID
        ORDER BY   editedData.lastUpdated DESC;

      ELSE
        SELECT     editedDataID, editedData.label, editedData.filename,
                   editedData.rawDataID, rawData.experimentID,
                   timestamp2UTC( editedData.lastUpdated) AS UTC_lastUpdated, 
                   MD5( editedData.data ) AS checksum, LENGTH( editedData.data ) AS size,
                   experiment.type, editedData.editGUID
        FROM       editedData, rawData, experiment, experimentPerson
        WHERE      experiment.experimentID = experimentPerson.experimentID
        AND        rawData.experimentID = experiment.experimentID
        AND        editedData.rawDataID = rawData.rawDataID
        ORDER BY   editedData.lastUpdated DESC;

      END IF;

    END IF;

  ELSEIF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
    IF ( (p_ID != 0) && (p_ID != @US3_ID) ) THEN
      -- Uh oh, can't do that
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view this experiment';
     
      SELECT @US3_LAST_ERRNO AS status;

    ELSEIF ( count_experiments( p_personGUID, p_password, @US3_ID ) < 1 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';
   
      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      -- Ok, user wants his own info
      SELECT @OK AS status;

      SELECT     editedDataID, editedData.label, editedData.filename,
                 editedData.rawDataID, rawData.experimentID, 
                 timestamp2UTC( editedData.lastUpdated) AS UTC_lastUpdated, 
                 MD5( editedData.data ) AS checksum, LENGTH( editedData.data ) AS size,
                 experiment.type, editedData.editGUID
      FROM       editedData, rawData, experiment, experimentPerson
      WHERE      experimentPerson.personID = @US3_ID
      AND        experiment.experimentID = experimentPerson.experimentID
      AND        rawData.experimentID = experiment.experimentID
      AND        editedData.rawDataID = rawData.rawDataID
      ORDER BY   editedData.lastUpdated DESC;

    END IF;

  END IF;

END$$

-- Get a list of editData descriptions for a specified runID
DROP PROCEDURE IF EXISTS get_edit_desc_by_runID$$
CREATE PROCEDURE get_edit_desc_by_runID ( p_personGUID   CHAR(36),
                                          p_password     VARCHAR(80),
                                          p_ID           INT,
                                          p_runID        VARCHAR(250) )
  READS SQL DATA

BEGIN
  DECLARE count_editData INT;
  DECLARE run_pattern VARCHAR(254);

  CALL config();
  SET run_pattern = CONCAT( p_runID, '.%' );
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  SELECT    COUNT(*)
  INTO      count_editData
  FROM      editedData
  WHERE     filename LIKE run_pattern;

  IF ( p_ID <= 0 ) THEN
      SET @US3_LAST_ERRNO = @EMPTY;
      SET @US3_LAST_ERROR = 'MySQL: The ID cannot be 0';
   
      SELECT @US3_LAST_ERRNO AS status;

  ELSEIF ( verify_userlevel( p_personGUID, p_password, @US3_ADMIN ) = @OK ) THEN
    -- This is an admin; he can get more info
    IF ( count_editData < 1 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';
   
      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;
  
      SELECT     editedDataID, editedData.label, editedData.filename,
                 editedData.rawDataID, rawData.experimentID,
                 timestamp2UTC( editedData.lastUpdated) AS UTC_lastUpdated, 
                 MD5( editedData.data ) AS checksum, LENGTH( editedData.data ) AS size,
                 experiment.type, editedData.editGUID
      FROM       editedData, rawData, experiment, experimentPerson
      WHERE      experimentPerson.personID = p_ID
      AND        experiment.experimentID = experimentPerson.experimentID
      AND        editedData.filename LIKE run_pattern
      AND        rawData.experimentID = experiment.experimentID
      AND        editedData.rawDataID = rawData.rawDataID
      ORDER BY   editedData.lastUpdated DESC;

    END IF;

  ELSEIF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
    IF ( (p_ID != 0) && (p_ID != @US3_ID) ) THEN
      -- Uh oh, can't do that
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to view those edits';
     
    ELSEIF ( count_editData < 1 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';
   
      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      -- Ok, user wants his own info
      SELECT @OK AS status;

      SELECT     editedDataID, editedData.label, editedData.filename,
                 editedData.rawDataID, rawData.experimentID, 
                 timestamp2UTC( editedData.lastUpdated) AS UTC_lastUpdated, 
                 MD5( editedData.data ) AS checksum, LENGTH( editedData.data ) AS size,
                 experiment.type, editedData.editGUID
      FROM       editedData, rawData, experiment, experimentPerson
      WHERE      experimentPerson.personID = @US3_ID
      AND        editedData.filename LIKE run_pattern
      AND        experiment.experimentID = experimentPerson.experimentID
      AND        rawData.experimentID = experiment.experimentID
      AND        editedData.rawDataID = rawData.rawDataID
      ORDER BY   editedData.lastUpdated DESC;

    END IF;

  END IF;

END$$

-- Returns the editID associated with the given editGUID
DROP PROCEDURE IF EXISTS get_editID$$
CREATE PROCEDURE get_editID ( p_personGUID    CHAR(36),
                              p_password      VARCHAR(80),
                              p_editGUID      CHAR(36) )
  READS SQL DATA

BEGIN

  DECLARE count_editedData INT;

  CALL config();
  SET @US3_LAST_ERRNO  = @OK;
  SET @US3_LAST_ERROR  = '';
  SET count_editedData = 0;

  IF ( verify_user( p_personGUID, p_password ) = @OK ) THEN

    SELECT    COUNT(*)
    INTO      count_editedData
    FROM      editedData
    WHERE     editGUID = p_editGUID;

    IF ( TRIM( p_editGUID ) = '' ) THEN
      SET @US3_LAST_ERRNO = @EMPTY;
      SET @US3_LAST_ERROR = CONCAT( 'MySQL: The editGUID parameter to the ',
                                    'get_editID function cannot be empty' );

    ELSEIF ( count_editedData < 1 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';
 
      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;

      SELECT   editedDataID
      FROM     editedData
      WHERE    editGUID = p_editGUID;

    END IF;

  END IF;

END$$

-- INSERTs new editedData information about one c/c/w combination in an experiment
DROP PROCEDURE IF EXISTS new_editedData$$
CREATE PROCEDURE new_editedData ( p_personGUID   CHAR(36),
                                  p_password     VARCHAR(80),
                                  p_rawDataID    INT,
                                  p_editGUID     CHAR(36),
                                  p_label        VARCHAR(80),
                                  p_filename     VARCHAR(255),
                                  p_comment      TEXT )
  MODIFIES SQL DATA

BEGIN

  DECLARE null_field     TINYINT DEFAULT 0;
  DECLARE l_experimentID INT;

  DECLARE CONTINUE HANDLER FOR 1048
    SET null_field = 1;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
  SET @LAST_INSERT_ID = 0;
 
  -- Get the experimentID so we can verify permission on this data
  SELECT     experimentID
  INTO       l_experimentID
  FROM       rawData
  WHERE      rawDataID = p_rawDataID;

  IF ( verify_experiment_permission( p_personGUID, p_password, l_experimentID ) = @OK ) THEN
 
    -- This is either an admin, or a person inquiring about his own experiment
    INSERT INTO editedData SET
      rawDataID     = p_rawDataID,
      editGUID      = p_editGUID,
      label         = p_label,
      filename      = p_filename,
      comment       = p_comment,
      lastUpdated   = NOW();
   
    IF ( null_field = 1 ) THEN
      SET @US3_LAST_ERRNO = @INSERTNULL;
      SET @US3_LAST_ERROR = "MySQL: Attempt to insert NULL value in the editedData table";

    ELSE
      SET @LAST_INSERT_ID  = LAST_INSERT_ID();

    END IF;
   
   END IF;

  SELECT @US3_LAST_ERRNO AS status;

END$$

-- SELECTs editedData information about one edit profile
DROP PROCEDURE IF EXISTS get_editedData$$
CREATE PROCEDURE get_editedData ( p_personGUID   CHAR(36),
                                  p_password     VARCHAR(80),
                                  p_editedDataID INT )
  READS SQL DATA

BEGIN

  DECLARE count_editedData   INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
 
  SELECT     COUNT(*)
  INTO       count_editedData
  FROM       editedData
  WHERE      editedDataID = p_editedDataID;

  IF ( count_editedData = 0 ) THEN
    SET @US3_LAST_ERRNO = @NOROWS;
    SET @US3_LAST_ERROR = 'MySQL: no rows returned';

    SELECT @US3_LAST_ERRNO AS status;

  ELSEIF ( verify_editData_permission( p_personGUID, p_password, p_editedDataID ) = @OK ) THEN
    -- This is either an admin, or a person inquiring about his own experiment
    SELECT @OK as status;

    SELECT  rawDataID, editGUID, label, filename, comment, 
            timestamp2UTC( lastUpdated ) AS UTC_lastUpdated, 
            MD5( data ) AS checksum, LENGTH( data ) AS size
    FROM    editedData
    WHERE   editedDataID = p_editedDataID;

  ELSE
    SELECT @US3_LAST_ERRNO AS status;

  END IF;

END$$

-- UPDATEs existing editedData information about one c/c/w combination in an experiment
DROP PROCEDURE IF EXISTS update_editedData$$
CREATE PROCEDURE update_editedData ( p_personGUID   CHAR(36),
                                     p_password     VARCHAR(80),
                                     p_editedDataID INT,
                                     p_rawDataID    INT,
                                     p_editGUID     CHAR(36),
                                     p_label        VARCHAR(80),
                                     p_filename     VARCHAR(255),
                                     p_comment      TEXT )
  MODIFIES SQL DATA

BEGIN

  DECLARE not_found      TINYINT DEFAULT 0;
  DECLARE null_field     TINYINT DEFAULT 0;
  DECLARE l_experimentID INT;

  DECLARE CONTINUE HANDLER FOR NOT FOUND
    SET not_found = 1;

  DECLARE CONTINUE HANDLER FOR 1048
    SET null_field = 1;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
 
  -- Get the experimentID so we can verify permission on this data
  SELECT     experimentID
  INTO       l_experimentID
  FROM       rawData
  WHERE      rawDataID = p_rawDataID;

  IF ( verify_experiment_permission( p_personGUID, p_password, l_experimentID ) = @OK ) THEN
 
    -- This is either an admin, or a person inquiring about his own experiment
    UPDATE editedData SET
      rawDataID     = p_rawDataID,
      editGUID      = p_editGUID,
      label         = p_label,
      filename      = p_filename,
      comment       = p_comment,
      lastUpdated   = NOW()
    WHERE editedDataID = p_editedDataID;
   
    IF ( not_found = 1 ) THEN
      SET @US3_LAST_ERRNO = @NO_EDITDATA;
      SET @US3_LAST_ERROR = "MySQL: No edit profile with that ID exists";

    ELSEIF ( null_field = 1 ) THEN
      SET @US3_LAST_ERRNO = @INSERTNULL;
      SET @US3_LAST_ERROR = "MySQL: Attempt to update with a NULL value in the editedData table";

    END IF;
   
   END IF;

  SELECT @US3_LAST_ERRNO AS status;

END$$

-- The GMP protection policy of delete_editedData (below), which reads
-- autoflowModelsLink itself.  A model is a GMP model when
--
--   - a valid modelsDesc of autoflowModelsLink lists it as a modelID
--     member of an object in the arrays under the keys 2DSA_IT, 2DSA_MC
--     and PCSA -- the keys and the shape UltraScan3 reads
--     (US_DataTree::parse_models_desc_json in us_manage_data; the LIMS
--     writes the same).  Models of the other stages (2DSA, 2DSA_FM, ...)
--     are not protected, as in UltraScan3, and neither is a modelID in a
--     stage whose value is an object rather than an array (UltraScan3
--     reads only arrays).  A modelID may be a string, which must be the
--     model's ID exactly ("9405", not " 9405", "09405" or "9405,9406"),
--     or a number equal to it (9405 or 9405.0, not 9404.6); a number a
--     double cannot hold (1e400, which MariaDB's JSON accepts) names no
--     model;
--   - a modelsDesc that is not valid JSON (possible in a table created on
--     MariaDB before 10.4.3, whose JSON columns had no CHECK yet, or in a
--     column changed to TEXT) cannot be read by key.  UltraScan3 ignores
--     such a row, but it still names GMP models, and a deletion cannot be
--     undone, so here it names, under any key, the run of digits that
--     starts within 8 characters after each "modelID" in its text (the
--     ID of {"modelID":"9405" and of "modelID": 9405, also in a
--     truncated text) -- written as the model's ID exactly: a run with a
--     leading zero ("09405") names no model, nor does one that starts 8
--     or more characters further on.  Such a row does not make the JSON
--     functions fail: it used to stop every edit deletion on MariaDB
--     (error 4038).
--   - NULL is no reference.
--
-- autoflow_model_ids, which gathered every GMP model ID of the table into
-- one list, is gone: it took time quadratic in the number of links, and
-- answered anyone, without a login.  model_in_autoflow went before it.
DROP FUNCTION IF EXISTS model_in_autoflow$$
DROP PROCEDURE IF EXISTS autoflow_model_ids$$

-- Is model p_modelID another investigator's, as far as the caller verified
-- last in this connection is concerned?  1 when the caller is not an
-- administrator, has no modelPerson row for the model, and somebody else
-- has one.  A model with no modelPerson row at all is nobody's: 0.
--
-- It reads @US3_ID and @USERLEVEL, which check_user() sets, and
-- @US3_ADMIN, which config() sets, so the caller must have been verified
-- in the same procedure call first.  The modelPerson rows are read with a
-- locking read (shared), so that inside a REPEATABLE READ transaction it
-- answers for the rows as they are, not as the transaction's snapshot has
-- them.
DROP FUNCTION IF EXISTS model_of_other_investigator$$
CREATE FUNCTION model_of_other_investigator( p_modelID INT )
  RETURNS TINYINT
  READS SQL DATA

BEGIN
  DECLARE l_mine   INT DEFAULT 0;
  DECLARE l_others INT DEFAULT 0;

  IF ( @USERLEVEL >= @US3_ADMIN ) THEN
    RETURN 0;
  END IF;

  SELECT SUM( personID = @US3_ID ), SUM( personID != @US3_ID )
  INTO   l_mine, l_others
  FROM   modelPerson
  WHERE  modelID = p_modelID
  LOCK IN SHARE MODE;

  RETURN ( COALESCE( l_mine, 0 ) = 0 AND COALESCE( l_others, 0 ) > 0 );

END$$

-- DELETEs an edit profile, plus the records that depend on it:
--   - its report documents (and their document links);
--   - every noise record computed from it (noise.editedDataID), whichever
--     model it was fitted with -- a global fit's noise names a model of
--     another edit, and it is this edit's noise all the same (the noise
--     table's foreign key forbids it to outlive the edit);
--   - every noise record fitted with one of its models, whichever edit it
--     was computed from;
--   - its models (and their modelPerson rows) and pcsa_modelrecs.
--
-- Who may delete it
--   An administrator, or anyone with an experimentPerson row for the
--   edit's experiment (verify_catalog_experiment(), us3_catalog_procs.sql),
--   the same for every experiment.  It used verify_editData_permission(),
--   which lets anybody modify experiment 1, a "magic" ID that is a real
--   experiment of some investigator on many servers.  Otherwise
--   @NOTPERMITTED; @NO_EDITDATA when the edit does not exist, and
--   @NO_EXPERIMENT when its experiment does not.  The special "UNASSIGNED"
--   edit (editedDataID 1) cannot be deleted at all (@NOTPERMITTED): every
--   investigator's models may be linked to it.
--
-- What it will not take along (@NOTPERMITTED, nothing deleted)
--   An ordinary user's listings show only that user's own models and noise,
--   so a client cannot show, or check, what else an edit removal would
--   take.  The call is therefore refused, and the message names the
--   records, when the models or noise it would delete include
--     - a model the GMP framework refers to (the policy above:
--       autoflowModelsLink lists it under 2DSA_IT, 2DSA_MC or PCSA, or a
--       row that is not valid JSON names it), or noise fitted with one --
--       for everybody, administrators included;
--     - for anyone but an administrator, a model of another investigator
--       (model_of_other_investigator(): somebody else's modelPerson row,
--       none of the caller's), or noise fitted with one.
--   A model with no modelPerson row is nobody's and does not stop the
--   removal.  The models and noise in question, and their modelPerson
--   rows, are read with locking reads inside the transaction (or
--   savepoint) the deletes run in, so they are checked as they are -- also
--   inside a caller's REPEATABLE READ transaction whose snapshot is older
--   -- and noise another connection records against the edit meanwhile
--   waits for the call to end.  autoflowModelsLink is read after those
--   row locks are taken, with a shared-locking read (LOCK IN SHARE MODE),
--   which sees the links as they are: a GMP link committed while the call
--   waited for one of the locks is seen, also inside a caller's
--   transaction whose snapshot is older than that link.  The read locks
--   every row of autoflowModelsLink, and under REPEATABLE READ the gaps
--   between them, until the transaction ends -- the call's own, or the
--   caller's: meanwhile a connection that inserts, changes or deletes a
--   GMP link waits (and fails with error 1205 after
--   innodb_lock_wait_timeout, 50 s by default).  For an edit with no
--   models and no noise, which no link can protect, the call neither
--   reads nor locks autoflowModelsLink.  On a refusal inside a
--   caller's transaction the locks stay until that transaction ends
--   (InnoDB keeps row locks across ROLLBACK TO SAVEPOINT).
--   Under READ COMMITTED (a caller's transaction, or the session's
--   isolation level) InnoDB takes no gap locks, so another connection can
--   commit a model or noise record against the edit after the call
--   checked the edit's records.  The call deletes only the records it
--   checked: such a newcomer stays, the edit's own delete fails on its
--   foreign key, and the call answers @CONSTRAINT_FAILED, nothing deleted.
--
-- All or nothing
--   The deletes run in a transaction of their own when the caller is not
--   in one; inside a caller's transaction (a client may wrap several writes
--   in one, as UltraScan3 does when it removes an edit) they run under the
--   savepoint us3_delete_editedData_sp instead, since START TRANSACTION
--   would commit the caller's transaction.  With autocommit off there is
--   always a transaction, and the caller commits it.  If a delete fails,
--   everything this call deleted is rolled back (to the savepoint, leaving
--   the caller's transaction open with its own work), and the status says
--   why: @CONSTRAINT_FAILED for a foreign key that still refers to the
--   edit, @ERROR for anything else (a read-only transaction, say), with
--   the server's message in @US3_LAST_ERROR.
--
-- Deadlocks
--   A deadlock (1213) makes the server roll back the whole transaction.
--   In a transaction of its own that only undoes this call: the status is
--   @ERROR, and the call can be repeated.  Inside a caller's transaction it
--   also undoes everything the caller did before; that is not reported as
--   a status but raised again as error 1213 (SQLSTATE 40001), as for any
--   other statement that deadlocks, so that a client cannot take it for an
--   ordinary refusal and carry on in a transaction that is gone.  The
--   same goes for any other error after which the savepoint is gone (a
--   lock wait timeout with innodb_rollback_on_timeout on).  @US3_LAST_ERRNO
--   is then @ERROR and @US3_LAST_ERROR says what happened.
--
-- Other investigators' records
--   Ownership is checked by model (modelPerson): a noise record is the
--   record of whoever owns the model it was fitted with, whatever edit or
--   experiment it was computed from.  So:
--     - an administrator's call deletes, without asking, the models other
--       investigators fitted to this edit, every noise record fitted with
--       them, and the noise recorded against this edit for another
--       investigator's model of another edit (that model stays) -- the
--       same records that make anyone else's call refuse, as above;
--     - anyone's call, administrator or not, deletes the edit's models
--       that have no modelPerson row and their noise, and every noise
--       record fitted with one of the edit's models that it may delete,
--       also when that noise was computed from an edit in another
--       experiment, of another investigator, on which the caller has no
--       permission at all (global-fit noise; the edit itself stays);
--     - report documents of the edit go with it (they have no owner).
--   No model of another edit is ever deleted.
DROP PROCEDURE IF EXISTS delete_editedData$$
CREATE PROCEDURE delete_editedData ( p_personGUID   CHAR(36),
                                     p_password     VARCHAR(80),
                                     p_editedDataID INT )
  MODIFIES SQL DATA

BEGIN
  DECLARE l_in_trx         TINYINT DEFAULT 1;
  DECLARE l_started        TINYINT DEFAULT 0;
  DECLARE l_lost           TINYINT DEFAULT 0;
  DECLARE l_errno          INT     DEFAULT 0;
  DECLARE l_message        TEXT    DEFAULT '';
  DECLARE l_status         INT;
  DECLARE l_count_edits    INT     DEFAULT 0;
  DECLARE l_experimentID   INT     DEFAULT NULL;
  DECLARE l_gmp_models     TEXT    DEFAULT NULL;
  DECLARE l_other_models   TEXT    DEFAULT NULL;
  DECLARE l_gmp_noise      TEXT    DEFAULT NULL;
  DECLARE l_other_noise    TEXT    DEFAULT NULL;
  DECLARE l_gmp_noise2     TEXT    DEFAULT NULL;
  DECLARE l_other_noise2   TEXT    DEFAULT NULL;
  DECLARE l_candidates     LONGBLOB DEFAULT ',';
  DECLARE l_model_ids      LONGBLOB DEFAULT ',';
  DECLARE l_noise_ids      LONGBLOB DEFAULT ',';
  DECLARE l_gmp_ids        LONGBLOB DEFAULT ',';

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1
      l_errno = MYSQL_ERRNO, l_message = MESSAGE_TEXT;

    IF ( l_started = 1 ) THEN
      IF ( l_errno = 1213 ) THEN
        -- The server has rolled back the whole transaction, savepoint and
        -- all; there is nothing left to undo
        SET l_lost = l_in_trx;

      ELSEIF ( l_in_trx = 1 ) THEN
        BEGIN
          -- The savepoint is gone when the server rolled the transaction
          -- back itself
          DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET l_lost = 1;
          ROLLBACK TO SAVEPOINT us3_delete_editedData_sp;
          IF ( l_lost = 0 ) THEN
            RELEASE SAVEPOINT us3_delete_editedData_sp;
          END IF;
        END;

      ELSE
        ROLLBACK;

      END IF;
    END IF;

    SET @US3_LAST_ERRNO = @ERROR;

    IF ( l_lost = 1 ) THEN
      SET @US3_LAST_ERROR = CONCAT( 'MySQL: the edit was not deleted: error ',
                                    l_errno, ': ', l_message, ' -- the server ',
                                    'rolled back the whole transaction, with ',
                                    'everything done in it before this call' );

      IF ( l_errno = 1213 ) THEN
        SIGNAL SQLSTATE '40001'
          SET MYSQL_ERRNO  = 1213,
              MESSAGE_TEXT = 'delete_editedData: deadlock; the server rolled back the whole transaction, the caller''s earlier work too';
      ELSE
        SET l_message = LEFT( CONCAT( 'delete_editedData: the server rolled back the whole transaction: ',
                                      l_message ), 128 );
        SIGNAL SQLSTATE 'HY000'
          SET MYSQL_ERRNO  = l_errno,
              MESSAGE_TEXT = l_message;
      END IF;

    END IF;

    IF ( l_errno IN ( 1451, 1452 ) ) THEN
      SET @US3_LAST_ERRNO = @CONSTRAINT_FAILED;
    END IF;

    SET @US3_LAST_ERROR = CONCAT( 'MySQL: the edit was not deleted, and nothing ',
                                  'that depends on it was: error ', l_errno,
                                  ': ', l_message );

    SELECT @US3_LAST_ERRNO AS status;

  END;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  -- verify_catalog_experiment() matches experimentPerson against @US3_ID
  -- and @USERLEVEL, which verify_user() sets
  SET l_status = verify_user( p_personGUID, p_password );

  SELECT     COUNT(*), MAX( r.experimentID )
  INTO       l_count_edits, l_experimentID
  FROM       editedData d
  LEFT JOIN  rawData r ON ( r.rawDataID = d.rawDataID )
  WHERE      d.editedDataID = p_editedDataID;

  IF ( l_status != @OK ) THEN
    -- check_user() has recorded why in @US3_LAST_ERROR
    SET @US3_LAST_ERRNO = l_status;

  ELSEIF ( p_editedDataID = 1 ) THEN
    SET @US3_LAST_ERRNO = @NOTPERMITTED;
    SET @US3_LAST_ERROR = 'MySQL: the UNASSIGNED edit profile cannot be deleted';

  ELSEIF ( l_count_edits = 0 ) THEN
    SET @US3_LAST_ERRNO = @NO_EDITDATA;
    SET @US3_LAST_ERROR = 'MySQL: no edit profile with that ID exists';

  ELSEIF ( verify_catalog_experiment( l_experimentID ) != @OK ) THEN
    -- @NO_EXPERIMENT or @NOTPERMITTED
    IF ( @US3_LAST_ERRNO = @NOTPERMITTED ) THEN
      SET @US3_LAST_ERROR = 'MySQL: you do not have permission to modify this experiment';
    END IF;

  ELSE

    -- Is the caller in a transaction?  A savepoint outlives the statement
    -- that set it only inside one; outside, autocommit ends it at once and
    -- releasing it fails.  (@@in_transaction would say so directly, but
    -- MySQL does not have it.)
    BEGIN
      DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET l_in_trx = 0;
      SAVEPOINT us3_delete_editedData_sp;
      RELEASE SAVEPOINT us3_delete_editedData_sp;
    END;

    IF ( l_in_trx = 1 ) THEN
      SAVEPOINT us3_delete_editedData_sp;
    ELSE
      START TRANSACTION;
    END IF;
    SET l_started = 1;

    -- What would go that must not: the edit's models, the noise computed
    -- from the edit, and the noise fitted with its models -- read with
    -- locking reads, which see what is committed now even under the
    -- snapshot of a caller's REPEATABLE READ transaction.  They lock only
    -- rows the deletes below lock anyway.  Another investigator's records
    -- first: these reads take the row locks, and may wait for them.
    SELECT     GROUP_CONCAT( IF( model_of_other_investigator( modelID ) = 1, modelID, NULL )
                             ORDER BY modelID )
    INTO       l_other_models
    FROM       model
    WHERE      editedDataID = p_editedDataID
    FOR UPDATE;

    SELECT     GROUP_CONCAT( IF( model_of_other_investigator( modelID ) = 1, noiseID, NULL )
                             ORDER BY noiseID )
    INTO       l_other_noise
    FROM       noise
    WHERE      editedDataID = p_editedDataID
    FOR UPDATE;

    SELECT     GROUP_CONCAT( IF( model_of_other_investigator( n.modelID ) = 1, n.noiseID, NULL )
                             ORDER BY n.noiseID )
    INTO       l_other_noise2
    FROM       model m
    JOIN       noise n ON ( n.modelID = m.modelID )
    WHERE      m.editedDataID = p_editedDataID
    AND        n.editedDataID != p_editedDataID
    FOR UPDATE;

    -- The edit's models (l_model_ids) and the noise recorded against it
    -- (l_noise_ids), each as a list ",id,id,...,": the records checked
    -- above and below, read with locking reads of rows locked above, so
    -- that they are the rows as they are.  The deletes take only these.
    -- Under READ COMMITTED, which takes no gap locks, another connection
    -- can commit a model or noise record against the edit after these
    -- reads; it stays, and the edit's own delete then fails on its
    -- foreign key (@CONSTRAINT_FAILED, everything rolled back) rather than
    -- deleting a record nobody checked.  (Noise fitted with one of the
    -- edit's models is that model's, and goes with it however late it
    -- came: the model was checked.)  And the models whose GMP links
    -- matter (l_candidates): the edit's models (the noise fitted with
    -- them is theirs) and the models the noise recorded against the edit
    -- was fitted with.
    BEGIN
      DECLARE l_done  TINYINT DEFAULT 0;
      DECLARE l_model INT;
      DECLARE l_noise INT;

      DECLARE c_models CURSOR FOR
        SELECT   modelID
        FROM     model
        WHERE    editedDataID = p_editedDataID
        FOR UPDATE;

      DECLARE c_noise_models CURSOR FOR
        SELECT   noiseID, modelID
        FROM     noise
        WHERE    editedDataID = p_editedDataID
        FOR UPDATE;

      DECLARE CONTINUE HANDLER FOR NOT FOUND SET l_done = 1;

      OPEN c_models;
      models: LOOP
        FETCH c_models INTO l_model;
        IF ( l_done = 1 ) THEN
          LEAVE models;
        END IF;
        SET l_candidates = CONCAT( l_candidates, l_model, ',' );
      END LOOP;
      CLOSE c_models;
      SET l_model_ids = l_candidates;

      SET l_done = 0;
      OPEN c_noise_models;
      noise_models: LOOP
        FETCH c_noise_models INTO l_noise, l_model;
        IF ( l_done = 1 ) THEN
          LEAVE noise_models;
        END IF;
        SET l_noise_ids = CONCAT( l_noise_ids, l_noise, ',' );
        IF ( LOCATE( CONCAT( ',', l_model, ',' ), l_candidates ) = 0 ) THEN
          SET l_candidates = CONCAT( l_candidates, l_model, ',' );
        END IF;
      END LOOP;
      CLOSE c_noise_models;
    END;

    -- Which of them GMP refers to (the policy above the procedure), into
    -- l_gmp_ids, ",id,id,...,".  autoflowModelsLink is read only now that
    -- the rows are locked, and with a locking read, so that a link
    -- committed while this call waited for a lock is seen: inside a
    -- caller's transaction a plain read would see the snapshot that the
    -- plain reads at the start of the call took.  The shared locks hold
    -- every row of the table, and under REPEATABLE READ its gaps, until
    -- the transaction ends; GMP writers wait meanwhile.  Every row once
    -- (none when there are no candidates); each ID a row names is looked
    -- up in the short candidate list, so the call costs one pass over the
    -- table, and its time grows linearly with the number of links.
    -- Only JSON_VALID, JSON_EXTRACT, JSON_LENGTH and JSON_UNQUOTE (MySQL
    -- 5.7.8, MariaDB 10.2.3; us3.sql's JSON column needs MariaDB 10.2.7),
    -- not JSON_TABLE (MySQL 8.0.4, MariaDB 10.6).
    BEGIN
      DECLARE l_done   TINYINT DEFAULT 0;
      DECLARE l_desc   LONGTEXT CHARACTER SET utf8mb4;
      DECLARE l_ids    LONGTEXT CHARACTER SET utf8mb4;
      DECLARE l_value  LONGTEXT CHARACTER SET utf8mb4;
      DECLARE l_id     LONGBLOB;
      DECLARE l_raw    LONGBLOB;
      DECLARE l_count  INT;
      DECLARE l_i      INT;
      DECLARE l_pos    INT;
      DECLARE l_start  INT;
      DECLARE l_end    INT;
      DECLARE l_length INT;
      DECLARE l_number DOUBLE;
      DECLARE l_valid  TINYINT;
      DECLARE l_few    TINYINT;
      DECLARE l_maybe  TINYINT;
      DECLARE l_cpos   INT;
      DECLARE l_cend   INT;

      DECLARE c_links CURSOR FOR
        SELECT modelsDesc
        FROM   autoflowModelsLink
        WHERE  modelsDesc IS NOT NULL
        LOCK IN SHARE MODE;

      DECLARE CONTINUE HANDLER FOR NOT FOUND SET l_done = 1;

      -- With no candidates (an edit with no models and no noise) there is
      -- nothing a link could protect, and the table is not read at all
      IF ( l_candidates = ',' ) THEN
        SET l_done = 1;
      ELSE
        OPEN c_links;
      END IF;

      -- With a few candidates, the IDs a row names are looked at one by
      -- one only when its text may hold one of them; see below
      SET l_few = ( LENGTH( l_candidates ) - LENGTH( REPLACE( l_candidates, ',', '' ) ) <= 33 );

      links: LOOP
        IF ( l_done = 0 ) THEN
          FETCH c_links INTO l_desc;
        END IF;
        IF ( l_done = 1 ) THEN
          LEAVE links;
        END IF;

        SET l_valid = JSON_VALID( l_desc );
        IF ( l_valid ) THEN
          -- An array of the stages' modelID values, NULL when there are none
          SET l_ids   = JSON_EXTRACT( l_desc, '$."2DSA_IT"[*].modelID',
                                              '$."2DSA_MC"[*].modelID',
                                              '$.PCSA[*].modelID' );
          SET l_raw   = CAST( l_ids AS BINARY );
        ELSE
          SET l_raw   = CAST( l_desc AS BINARY );
        END IF;

        -- The pre-filter.  Taking the IDs one by one is what a row costs,
        -- and most rows name none of the candidates.  Text that holds none
        -- of their IDs, bytewise, names none -- by the rules below a
        -- string must be the ID itself, a number written without an
        -- exponent holds its digits (9404.0 holds 9404), and a row that is
        -- not JSON is read by its digits -- unless it is JSON with a
        -- backslash (an escape such as \u0039 can spell a digit) or an e
        -- (an exponent: 9.404e3) in it.  For JSON the text is that of the
        -- stages' modelID values alone (l_ids: no GUID, no key), so the
        -- test is short.  With many candidates (one LOCATE each would
        -- cost more than it saves) every row is looked at.
        IF ( l_few = 1 ) THEN
          SET l_maybe = 0;
          SET l_cpos  = 2;
          WHILE ( l_maybe = 0 AND l_cpos < LENGTH( l_candidates ) ) DO
            SET l_cend = LOCATE( ',', l_candidates, l_cpos );
            IF ( LOCATE( SUBSTRING( l_candidates, l_cpos, l_cend - l_cpos ), l_raw ) > 0 ) THEN
              SET l_maybe = 1;
            END IF;
            SET l_cpos = l_cend + 1;
          END WHILE;

          IF ( l_maybe = 0 AND l_valid AND
               ( LOCATE( CHAR( 92 ), l_raw ) > 0 ) ) THEN
            SET l_maybe = 1;
          END IF;

          IF ( l_maybe = 0 AND l_valid AND
               ( LOCATE( 'e', l_raw ) > 0 OR LOCATE( 'E', l_raw ) > 0 ) ) THEN
            SET l_maybe = 1;
          END IF;

          IF ( COALESCE( l_maybe, 1 ) = 0 ) THEN
            ITERATE links;
          END IF;
        END IF;

        IF ( l_valid ) THEN
          SET l_count = COALESCE( JSON_LENGTH( l_ids ), 0 );
          SET l_i     = 0;

          WHILE ( l_i < l_count ) DO
            SET l_value = JSON_EXTRACT( l_ids, CONCAT( '$[', l_i, ']' ) );
            SET l_id    = NULL;

            IF ( LEFT( l_value, 1 ) = '"' ) THEN
              -- A string: as it is (with a comma in it, it is no list item)
              SET l_id = REPLACE( JSON_UNQUOTE( l_value ), ',', ' ' );

            ELSEIF ( LEFT( l_value, 1 ) IN ( '-', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' ) ) THEN
              -- A number: when it is a whole number a model ID can be.  One
              -- a double cannot hold (MariaDB's JSON accepts 1e400) is
              -- none, and must not fail the call (error 1292)
              SET l_number = NULL;
              BEGIN
                DECLARE CONTINUE HANDLER FOR 1292, 1264, 1367, 1690, SQLWARNING
                  SET l_number = NULL;
                SET l_number = l_value + 0;
              END;
              IF ( l_number = FLOOR( l_number ) AND ABS( l_number ) < 2147483648 ) THEN
                SET l_id = CAST( l_number AS SIGNED );
              END IF;

            END IF;

            IF ( LOCATE( CONCAT( ',', l_id, ',' ), l_candidates ) > 0 AND
                 LOCATE( CONCAT( ',', l_id, ',' ), l_gmp_ids ) = 0 ) THEN
              SET l_gmp_ids = CONCAT( l_gmp_ids, l_id, ',' );
            END IF;

            SET l_i = l_i + 1;
          END WHILE;

        ELSE
          -- Not JSON: the digits after each "modelID", bytewise (l_raw)
          SET l_length = LENGTH( l_raw );
          SET l_pos    = LOCATE( 'modelID', l_raw );

          WHILE ( l_pos > 0 ) DO
            SET l_start = l_pos + 7;
            WHILE ( l_start < l_pos + 15 AND l_start <= l_length AND
                    SUBSTRING( l_raw, l_start, 1 ) NOT BETWEEN '0' AND '9' ) DO
              SET l_start = l_start + 1;
            END WHILE;

            SET l_end = l_start;
            WHILE ( l_end <= l_length AND SUBSTRING( l_raw, l_end, 1 ) BETWEEN '0' AND '9' ) DO
              SET l_end = l_end + 1;
            END WHILE;

            IF ( l_end > l_start ) THEN
              SET l_id = SUBSTRING( l_raw, l_start, l_end - l_start );
              IF ( LOCATE( CONCAT( ',', l_id, ',' ), l_candidates ) > 0 AND
                   LOCATE( CONCAT( ',', l_id, ',' ), l_gmp_ids ) = 0 ) THEN
                SET l_gmp_ids = CONCAT( l_gmp_ids, l_id, ',' );
              END IF;
            END IF;

            SET l_pos = LOCATE( 'modelID', l_raw, l_pos + 7 );
          END WHILE;

        END IF;

      END LOOP;

      IF ( l_candidates != ',' ) THEN
        CLOSE c_links;
      END IF;
    END;

    -- The edit's records that go with a GMP model (l_gmp_ids holds only
    -- candidates, so this is short)
    SELECT     GROUP_CONCAT( IF( LOCATE( CONCAT( ',', modelID, ',' ), l_gmp_ids ) > 0, modelID, NULL )
                             ORDER BY modelID )
    INTO       l_gmp_models
    FROM       model
    WHERE      editedDataID = p_editedDataID
    FOR UPDATE;

    SELECT     GROUP_CONCAT( IF( LOCATE( CONCAT( ',', modelID, ',' ), l_gmp_ids ) > 0, noiseID, NULL )
                             ORDER BY noiseID )
    INTO       l_gmp_noise
    FROM       noise
    WHERE      editedDataID = p_editedDataID
    FOR UPDATE;

    SELECT     GROUP_CONCAT( IF( LOCATE( CONCAT( ',', n.modelID, ',' ), l_gmp_ids ) > 0, n.noiseID, NULL )
                             ORDER BY n.noiseID )
    INTO       l_gmp_noise2
    FROM       model m
    JOIN       noise n ON ( n.modelID = m.modelID )
    WHERE      m.editedDataID = p_editedDataID
    AND        n.editedDataID != p_editedDataID
    FOR UPDATE;

    SET l_gmp_noise   = NULLIF( CONCAT_WS( ',', l_gmp_noise,   l_gmp_noise2   ), '' );
    SET l_other_noise = NULLIF( CONCAT_WS( ',', l_other_noise, l_other_noise2 ), '' );

    IF ( l_gmp_models IS NOT NULL OR l_gmp_noise IS NOT NULL ) THEN
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = CONCAT( 'MySQL: the edit was not deleted: it would take along ',
                                    'records the GMP framework refers to (',
                                    CONCAT_WS( '; ',
                                      CONCAT( 'models ', l_gmp_models ),
                                      CONCAT( 'noise of such models ', l_gmp_noise ) ),
                                    ')' );

    ELSEIF ( l_other_models IS NOT NULL OR l_other_noise IS NOT NULL ) THEN
      SET @US3_LAST_ERRNO = @NOTPERMITTED;
      SET @US3_LAST_ERROR = CONCAT( 'MySQL: the edit was not deleted: it would take along ',
                                    'records of another investigator, which only an ',
                                    'administrator may delete (',
                                    CONCAT_WS( '; ',
                                      CONCAT( 'models ', l_other_models ),
                                      CONCAT( 'noise of such models ', l_other_noise ) ),
                                    ')' );

    ELSE
      -- Children before parents, so that no foreign key is checked against
      -- a row that is about to go
      DELETE      reportDocument, documentLink
      FROM        reportDocument
      LEFT JOIN   documentLink ON ( documentLink.reportDocumentID = reportDocument.reportDocumentID )
      WHERE       reportDocument.editedDataID = p_editedDataID;

      -- Only the edit's records checked above (see l_model_ids)
      DELETE      FROM noise
      WHERE       editedDataID = p_editedDataID
      AND         LOCATE( CONCAT( ',', noiseID, ',' ), l_noise_ids ) > 0;

      DELETE      noise
      FROM        noise
      JOIN        model ON ( model.modelID = noise.modelID )
      WHERE       model.editedDataID = p_editedDataID
      AND         LOCATE( CONCAT( ',', model.modelID, ',' ), l_model_ids ) > 0;

      DELETE      modelPerson
      FROM        modelPerson
      JOIN        model ON ( model.modelID = modelPerson.modelID )
      WHERE       model.editedDataID = p_editedDataID
      AND         LOCATE( CONCAT( ',', model.modelID, ',' ), l_model_ids ) > 0;

      DELETE      FROM model
      WHERE       editedDataID = p_editedDataID
      AND         LOCATE( CONCAT( ',', modelID, ',' ), l_model_ids ) > 0;

      DELETE      FROM pcsa_modelrecs
      WHERE       editedDataID = p_editedDataID;

      DELETE      FROM editedData
      WHERE       editedDataID = p_editedDataID;

    END IF;

    -- A refusal deleted nothing, but ends the transaction or the savepoint
    -- all the same
    IF ( @US3_LAST_ERRNO = @OK ) THEN
      IF ( l_in_trx = 1 ) THEN
        RELEASE SAVEPOINT us3_delete_editedData_sp;
      ELSE
        COMMIT;
      END IF;
    ELSE
      IF ( l_in_trx = 1 ) THEN
        ROLLBACK TO SAVEPOINT us3_delete_editedData_sp;
        RELEASE SAVEPOINT us3_delete_editedData_sp;
      ELSE
        ROLLBACK;
      END IF;
    END IF;

  END IF;

  SELECT @US3_LAST_ERRNO AS status;

END$$

-- UPDATEs an editData record with the edit profile data
DROP PROCEDURE IF EXISTS upload_editData$$
CREATE PROCEDURE upload_editData ( p_personGUID   CHAR(36),
                                   p_password     VARCHAR(80),
                                   p_editedDataID INT,
                                   p_data         LONGBLOB,
                                   p_checksum     CHAR(33) )
  MODIFIES SQL DATA

BEGIN
  DECLARE l_checksum     CHAR(33);
  DECLARE l_experimentID INT;
  DECLARE not_found      TINYINT DEFAULT 0;

  DECLARE CONTINUE HANDLER FOR NOT FOUND
    SET not_found = 1;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
 
  -- Compare checksum with calculated checksum
  SET l_checksum = MD5( p_data );
  SET @DEBUG = CONCAT( l_checksum , ' ', p_checksum );

  IF ( l_checksum != p_checksum ) THEN

    -- Checksums don't match; abort
    SET @US3_LAST_ERRNO = @BAD_CHECKSUM;
    SET @US3_LAST_ERROR = "MySQL: Transmission error, bad checksum";

  ELSEIF ( verify_editData_permission( p_personGUID, p_password, p_editedDataID ) = @OK ) THEN
 
    -- This is either an admin, or a person inquiring about his own experiment
    UPDATE editedData SET
           data         = p_data
    WHERE  editedDataID = p_editedDataID;

    IF ( not_found = 1 ) THEN
      SET @US3_LAST_ERRNO = @NO_EDITDATA;
      SET @US3_LAST_ERROR = "MySQL: No edit profile with that ID exists";

    END IF;

  END IF;

  SELECT @US3_LAST_ERRNO AS status;

END$$

-- SELECTs an editedData record of xml data previously saved with upload_aucData
DROP PROCEDURE IF EXISTS download_editData$$
CREATE PROCEDURE download_editData ( p_personGUID   CHAR(36),
                                     p_password     VARCHAR(80),
                                     p_editedDataID INT )
  READS SQL DATA

BEGIN
  DECLARE l_count_editData INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
 
  -- Get information to verify that there are records
  SELECT COUNT(*)
  INTO   l_count_editData
  FROM   editedData
  WHERE  editedDataID = p_editedDataID;

SET @DEBUG = CONCAT('Edited data ID = ', p_editedDataID,
                    'Count = ', l_count_editData );
  IF ( l_count_editData != 1 ) THEN
    -- Probably no rows
    SET @US3_LAST_ERRNO = @NOROWS;
    SET @US3_LAST_ERROR = 'MySQL: no rows exist with that ID (or too many rows)';

    SELECT @NOROWS AS status;
    
  ELSEIF ( verify_editData_permission( p_personGUID, p_password, p_editedDataID ) != @OK ) THEN
 
    -- verify_experiment_permission must have thrown an error, so pass it on
    SELECT @US3_LAST_ERRNO AS status;

  ELSE

    -- This is either an admin, or a person inquiring about his own experiment
    SELECT @OK AS status;

    SELECT data, MD5( data )
    FROM   editedData
    WHERE  editedDataID = p_editedDataID;

  END IF;

END$$

-- Get a list of editedData filenames and editedDataIDs that correspond with this label
DROP PROCEDURE IF EXISTS get_editedDataFilenamesIDs_forReport$$
CREATE PROCEDURE get_editedDataFilenamesIDs_forReport ( p_personGUID   CHAR(36),
                                 	      	       p_password     VARCHAR(80),
                                  	     	       p_label VARCHAR(80),
					     	       p_eID   INT(11) )
  READS SQL DATA

BEGIN
  DECLARE count_editedData INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  SELECT     COUNT(*)
  INTO       count_editedData
  FROM       editedData
  WHERE      label = p_label AND editedDataID = p_eID;

  
  IF ( count_editedData = 0 ) THEN
    SET @US3_LAST_ERRNO = @NOROWS;
    SET @US3_LAST_ERROR = 'MySQL: no rows returned';

    SELECT @US3_LAST_ERRNO AS status;

  ELSE
    SELECT @OK AS status;

    SELECT   filename, editedDataID, rawDataID, timestamp2UTC( lastUpdated ) AS UTC_lastUpdated
    FROM     editedData
    WHERE    label = p_label AND editedDataID = p_eID;

  END IF;

END$$


-- COPY: no p_eID used: Get a list of editedData filenames and editedDataIDs that correspond with this label
DROP PROCEDURE IF EXISTS get_editedDataFilenamesIDs$$
CREATE PROCEDURE get_editedDataFilenamesIDs ( p_personGUID   CHAR(36),
                                 	     p_password     VARCHAR(80),
                                  	     p_label VARCHAR(80) )
  READS SQL DATA

BEGIN
  DECLARE count_editedData INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  SELECT     COUNT(*)
  INTO       count_editedData
  FROM       editedData
  WHERE      label = p_label;

  
  IF ( count_editedData = 0 ) THEN
    SET @US3_LAST_ERRNO = @NOROWS;
    SET @US3_LAST_ERROR = 'MySQL: no rows returned';

    SELECT @US3_LAST_ERRNO AS status;

  ELSE
    SELECT @OK AS status;

    SELECT   filename, editedDataID, rawDataID, timestamp2UTC( lastUpdated ) AS UTC_lastUpdated
    FROM     editedData
    WHERE    label = p_label;

  END IF;

END$$


