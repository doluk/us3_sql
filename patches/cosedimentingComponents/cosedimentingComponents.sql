-- -----------------------------------------------------
-- Table buffercosedLink
-- -----------------------------------------------------
DROP TABLE IF EXISTS buffercosedLink ;

CREATE  TABLE IF NOT EXISTS buffercosedLink (
  bufferID int(11) NOT NULL ,
  cosedComponentGUID CHAR(36) NOT NULL UNIQUE ,
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
DROP PROCEDURE IF EXISTS get_cosed_componentID;
CREATE PROCEDURE get_cosed_componentID ( p_personGUID CHAR(36),
                                p_password   VARCHAR(80),
                                p_cosed_componentGUID CHAR(36) )
  READS SQL DATA

BEGIN

  DECLARE count_buff INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
  SET count_buff   = 0;

  IF ( verify_user( p_personGUID, p_password ) = @OK ) THEN

    SELECT    COUNT(*)
    INTO      count_buff
    FROM      buffercosedLink
    WHERE     cosedComponentGUID = p_cosed_componentGUID;

    IF ( TRIM( p_cosed_componentGUID ) = '' ) THEN
      SET @US3_LAST_ERRNO = @EMPTY;
      SET @US3_LAST_ERROR = CONCAT( 'MySQL: The cosed_componentGUID parameter to the get_cosed_componentID ',
                                    'function cannot be empty' );

    ELSEIF ( count_buff < 1 ) THEN
      SET @US3_LAST_ERRNO = @NOROWS;
      SET @US3_LAST_ERROR = 'MySQL: no rows returned';

      SELECT @US3_LAST_ERRNO AS status;

    ELSE
      SELECT @OK AS status;

      SELECT   cosedComponentID
      FROM     buffercosedLink
      WHERE    cosedComponentGUID = p_cosed_componentGUID;

    END IF;

  END IF;

END;



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

      SELECT cosedComponentID, name, cosedComponentGUID
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

      SELECT   name, concentration, s_value, d_value, density, viscosity, overlaying, cosedComponentGUID
      FROM     buffercosedLink
      WHERE    cosedComponentID = p_componentID;

    END IF;

  ELSE
    SELECT @US3_LAST_ERRNO AS status;

  END IF;

END;

-- adds a new cosedimenting component from cosedComponent
CREATE PROCEDURE add_cosed_component ( p_personGUID    CHAR(36),
                                        p_password      VARCHAR(80),
                                        p_componentGUID CHAR(36),
                                        p_bufferID      INT,
                                        p_name          TEXT,
                                        p_concentration FLOAT,
                                        p_s_coeff       FLOAT,
                                        p_d_coeff       FLOAT,
                                        p_overlaying    TINYINT(1),
                                        p_density       TEXT,
                                        p_viscosity     TEXT)
  MODIFIES SQL DATA

BEGIN
  DECLARE count_buffers    INT;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';
  SET @LAST_INSERT_ID = 0;

  SELECT     COUNT(*)
  INTO       count_buffers
  FROM       buffer
  WHERE      bufferID = p_bufferID;

  IF ( verify_buffer_permission( p_personGUID, p_password, p_bufferID ) = @OK ) THEN
    IF ( count_buffers < 1 ) THEN
      SET @US3_LAST_ERRNO = @NO_BUFFER;
      SET @US3_LAST_ERROR = CONCAT('MySQL: No buffer with ID ',
                                   p_bufferID,
                                   ' exists' );

    ELSE
      INSERT INTO buffercosedlink SET
        cosedComponentGUID= p_componentGUID,
        bufferID          = p_bufferID,
        name              = p_name,
        concentration     = p_concentration,
        s_value           = p_s_coeff,
        d_value           = p_d_coeff,
        overlaying        = p_overlaying,
        density           = p_density,
        viscosity         = p_viscosity;

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

      SELECT   cosedComponentID, name, viscosity, density, concentration, s_value, d_value, overlaying, cosedComponentGUID
      FROM     buffercosedlink l
      WHERE    bufferID = p_bufferID
      ORDER BY name;

    END IF;

  END IF;

END;

DROP PROCEDURE IF EXISTS update_cosed_component;
CREATE PROCEDURE update_cosed_component ( p_personGUID    CHAR(36),
                                        p_password      VARCHAR(80),
                                        p_bufferID      INT,
                                        p_cosedID       INT,
                                        p_name          TEXT,
                                        p_concentration FLOAT,
                                        p_s_coeff       FLOAT,
                                        p_d_coeff       FLOAT,
                                        p_overlaying    TINYINT(1),
                                        p_density       TEXT,
                                        p_viscosity     TEXT)
  MODIFIES SQL DATA

BEGIN
  DECLARE not_found     TINYINT DEFAULT 0;

  DECLARE CONTINUE HANDLER FOR NOT FOUND
    SET not_found = 1;

  CALL config();
  SET @US3_LAST_ERRNO = @OK;
  SET @US3_LAST_ERROR = '';

  IF ( verify_buffer_permission( p_personGUID, p_password, p_bufferID ) = @OK ) THEN
    UPDATE buffercosedLink SET
      name            = p_name,
      concentration   = p_concentration,
      s_value         = p_s_coeff,
      d_value         = p_d_coeff,
      density         = p_density,
      viscosity       = p_viscosity,
      overlaying      = p_overlaying
    WHERE bufferID    = p_bufferID and
     cosedComponentID = p_cosedID;

    IF ( not_found = 1 ) THEN
      SET @US3_LAST_ERRNO = @NO_BUFFER;
      SET @US3_LAST_ERROR = "MySQL: No cosed component with that ID exists for this buffer ID";

    ELSE
      SET @LAST_INSERT_ID = LAST_INSERT_ID();

    END IF;

  END IF;

  SELECT @US3_LAST_ERRNO AS status;

END;