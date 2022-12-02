-- -----------------------------------------------------
-- Table buffercosedLink
-- -----------------------------------------------------
DROP TABLE IF EXISTS buffercosedLink ;

CREATE  TABLE IF NOT EXISTS buffercosedLink (
  bufferID int(11) NOT NULL ,
  cosedComponentID int(11) NOT NULL AUTO_INCREMENT ,
  name TEXT NULL DEFAULT NULL,
  concentration FLOAT NULL,
  s_value FLOAT DEFAULT NULL,
  d_value FLOAT DEFAULT NULL,
  density TEXT NULL DEFAULT NULL,
  viscosity TEXT NULL DEFAULT NULL,
  overlaying TINYINT(1) NOT NULL DEFAULT 0,
  INDEX ndx_bufferLink_bufferID (bufferID ASC) ,
  CONSTRAINT fk_buffercosedLink_bufferID
    FOREIGN KEY (bufferID )
    REFERENCES buffer (bufferID )
    ON DELETE CASCADE
    ON UPDATE CASCADE)
ENGINE = InnoDB;

-- -----------------------------------------------------
-- update existing procedures
-- -----------------------------------------------------

-- DELETEs a buffer, plus information in related tables
DROP PROCEDURE IF EXISTS delete_buffer;
CREATE PROCEDURE delete_buffer ( p_personGUID CHAR(36),
                                 p_password   VARCHAR(80),
                                 p_bufferID   INT )
  MODIFIES SQL DATA

BEGIN
  DECLARE count_buffers INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  IF ( verify_buffer_permission( p_personGUID, p_password, p_bufferID ) = @OK ) THEN

    -- Find out if this buffer is used in any solution first
    SELECT COUNT(*) INTO count_buffers
    FROM solutionBuffer
    WHERE bufferID = p_bufferID;

    IF ( count_buffers = 0 ) THEN

      DELETE FROM bufferLink
      WHERE bufferID = p_bufferID;

      DELETE FROM buffercosedLink
      WHERE bufferID = p_bufferID;

      DELETE FROM bufferPerson
      WHERE bufferID = p_bufferID;

      DELETE FROM extinctionProfile
      WHERE componentID = p_bufferID
      AND   componentType = 'Buffer';

      DELETE FROM buffer
      WHERE bufferID = p_bufferID;

    ELSE
      SET @US3_LAST_ERRNO = @BUFFER_IN_USE;
      SET @US3_LAST_ERROR = 'The buffer is in use in a solution';

    END IF;

  END IF;

  SELECT @US3_LAST_ERRNO AS status;

END;

-- DELETEs all components associated with a buffer
DROP PROCEDURE IF EXISTS delete_buffer_components;
CREATE PROCEDURE delete_buffer_components ( p_personGUID CHAR(36),
                                            p_password   VARCHAR(80),
                                            p_bufferID   INT )
  MODIFIES SQL DATA

BEGIN
  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  IF ( verify_buffer_permission( p_personGUID, p_password, p_bufferID ) = @OK ) THEN
    DELETE FROM bufferLink
    WHERE bufferID = p_bufferID;
    DELETE FROM buffercosedlink
    WHERE bufferID = p_bufferID;

  END IF;

  SELECT @US3_LAST_ERRNO AS status;

END;

-- -----------------------------------------------------
-- create new procedures
-- -----------------------------------------------------

-- SELECTs descriptions for all cosedimenting components
CREATE PROCEDURE get_cosed_component_desc ( p_personGUID CHAR(36),
                                             p_password   VARCHAR(80) )
  READS SQL DATA

BEGIN
  DECLARE count_components INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  IF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
    SELECT    COUNT(*)
    INTO      count_components
    FROM      buffercosedLink;

    IF ( count_components = 0 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';

      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;

      SELECT cosedComponentID, name
      FROM buffercosedLink
      ORDER BY name;

    END IF;

  END IF;

END;

-- Returns a more complete list of information about one cosedimenting component

CREATE PROCEDURE get_cosed_component_info ( p_personGUID  CHAR(36),
                                             p_password    VARCHAR(80),
                                             p_componentID INT )
  READS SQL DATA

BEGIN
  DECLARE count_components INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  SELECT     COUNT(*)
  INTO       count_components
  FROM       buffercosedLink
  WHERE      cosedComponentID = p_componentID;

  IF ( verify_user( p_personGUID, p_password ) = @OK ) THEN
    IF ( count_components = 0 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';

      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;

      SELECT   name, concentration, s_value, d_value, density, viscosity, overlaying
      FROM     buffercosedLink
      WHERE    cosedComponentID = p_componentID;

    END IF;

  ELSE
    SELECT @US3_LAST_ERRNO AS status;

  END IF;

END;

-- adds a new cosedimenting component from cosedComponent
CREATE PROCEDURE add_buffer_component ( p_personGUID    CHAR(36),
                                        p_password      VARCHAR(80),
                                        p_bufferID      INT,
                                        p_componentID   INT,
                                        p_concentration FLOAT )
  MODIFIES SQL DATA

BEGIN
  DECLARE count_buffers    INT;
  DECLARE count_components INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
  SET @LAST_INSERT_ID = 0;

  SELECT     COUNT(*)
  INTO       count_buffers
  FROM       buffer
  WHERE      bufferID = p_bufferID;

  SELECT     COUNT(*)
  INTO       count_components
  FROM       bufferComponent
  WHERE      bufferComponentID = p_componentID;

  IF ( verify_buffer_permission( p_personGUID, p_password, p_bufferID ) = @OK ) THEN
    IF ( count_buffers < 1 ) THEN
      SET @US3_LAST_ERRNO = @NO_BUFFER;
      SET @US3_LAST_ERROR = CONCAT('MySQL: No buffer with ID ',
                                   p_bufferID,
                                   ' exists' );

    ELSEIF ( count_components < 1 ) THEN
      SET @US3_LAST_ERRNO = @NO_COMPONENT;
      SET @US3_LAST_ERROR = CONCAT('MySQL: No buffer component with ID ',
                                   p_componentID,
                                   ' exists' );

    ELSE
      INSERT INTO bufferLink SET
        bufferID          = p_bufferID,
        bufferComponentID = p_componentID,
        concentration     = p_concentration;

      SET @LAST_INSERT_ID = LAST_INSERT_ID();

    END IF;

  END IF;

  SELECT @US3_LAST_ERRNO AS status;

END;


-- Returns information about all cosedimenting components of a single buffer
CREATE PROCEDURE get_cosed_components ( p_personGUID CHAR(36),
                                         p_password   VARCHAR(80),
                                         p_bufferID   INT )
  READS SQL DATA

BEGIN
  DECLARE count_components INT;
  DECLARE is_private       TINYINT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  SELECT     private
  INTO       is_private
  FROM       bufferPerson
  WHERE      bufferID = p_bufferID;

  -- Either the user needs access permissions or the buffer needs to be public
  IF ( ( verify_buffer_permission( p_personGUID, p_password, p_bufferID ) = @OK ) ||
       ( ( verify_user( p_personGUID, p_password ) = @OK ) && ! is_private ) ) THEN
    SELECT    COUNT(*)
    INTO      count_components
    FROM      buffercosedlink
    WHERE     bufferID = p_bufferID;

    IF ( count_components = 0 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';

      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;

      SELECT   cosedComponentID, name, viscosity, density, concentration, s_value, d_value, overlaying
      FROM     buffercosedlink l
      WHERE    bufferID = p_bufferID
      ORDER BY name;

    END IF;

  END IF;

END;