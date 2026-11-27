readme.txt

US3 Database and Stored Procedures Reference

For notes and a US3 Stored Procedures API reference see the US3 wiki.

the new instance creation relies on the database definition
(us3.sql), all the stored procedures, and the lims code to create a new
instance. The way I do it, I become the us3 user and run the
update-local.sh script first thing. This will update the us3 user's copy of
all of these files from subversion. Then I run the create new instance
stuff.

If any time you forget to update the code first it's not a terribly big
deal. You can do a subversion update of the lims code, and you can update
the stored procedures like this:

mysql -u user -p database <us3_procedures.sql

That file sources all the other sql files. If the us3.sql file was out of
date it's a little more difficult, because there are some records that get
populated in there as part of the setup process too. However, I believe I
have scripts that can be used to refresh that too.


Catalog procedures (us3_catalog_procs.sql, release 4.3.0-dev)

us3_catalog_procs.sql adds the procedures behind UltraScan3's data
catalog (us_manage_data, us_data_publication): get_experiment_summary,
get_rawData_by_experiment, get_editedData_by_experiment,
get_model_desc_by_experiment, get_noise_desc_by_experiment,
get_rawData_by_person and get_editedData_by_person, and the function
verify_catalog_experiment they use.  It only adds procedures; no table
changes.  us3_procedures.sql sources it, so an existing instance gets them
by re-running that file as above, or this file alone:

mysql -u user -p database <us3_catalog_procs.sql

Clients that find these procedures missing fall back on the older
one-record-at-a-time procedures, so nothing breaks on an instance that has
not been updated -- it is only slow to browse, which is easy to miss.
Clients treat two server errors as "missing": 1305 (the procedure does
not exist) and 1370 (it exists, but the account has no EXECUTE privilege
on it, as after creating the procedures as one account and granting
EXECUTE on the old ones only).  Anything else is an error, so a database
must not keep a procedure of the same name with a different parameter
list (error 1318).  Re-run the whole file rather than parts of it: the
catalog uses the procedures in three groups (listing, per experiment,
whole store) and falls back for each group on its own.

The header of us3_catalog_procs.sql documents the status codes these
procedures answer with, whose records they list, and in which experiment
a record is counted (a noise record: in its model's).
tests/catalog_smoke.sh checks them against a scratch database; see
tests/README.


Server versions

The procedures need MySQL 5.7.8 or later, or MariaDB 10.2.7 or later.
delete_editedData uses JSON_VALID, JSON_EXTRACT, JSON_LENGTH and
JSON_UNQUOTE, which came with MySQL 5.7.8 and MariaDB 10.2.3, and us3.sql
declares autoflowModelsLink.modelsDesc as JSON, a type MariaDB has from
10.2.7 (an alias for LONGTEXT; a CHECK ( JSON_VALID(...) ) since 10.4.3).
Nothing needs JSON_TABLE (MySQL 8.0.4, MariaDB 10.6).  The tests run on
MySQL 8.0.46 and MariaDB 10.11 (tests/README).


Upstream

These changes are on top of the two commits that added
us3_catalog_procs.sql to doluk/us3_sql ("Add per-experiment catalog
procedures" and "Add bulk catalog procedures that do not hash the data
blobs"), which ehb54/us3_sql does not have.  A pull request to
ehb54/us3_sql must carry those two commits as well as the ones after
them, or us3_procedures.sql sources a file that is not there.
