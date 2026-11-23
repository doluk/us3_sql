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


Catalog procedures (us3_catalog_procs.sql, release 4.3.0)

us3_catalog_procs.sql adds the procedures behind UltraScan3's data
catalog (us_manage_data, us_data_publication): get_experiment_summary,
get_rawData_by_experiment, get_editedData_by_experiment,
get_model_desc_by_experiment, get_noise_desc_by_experiment,
get_rawData_by_person and get_editedData_by_person.  It only adds
procedures; no table changes.  us3_procedures.sql sources it, so an
existing instance gets them by re-running that file as above, or this
file alone:

mysql -u user -p database <us3_catalog_procs.sql

Clients that find these procedures missing (MySQL error 1305) fall back
on the older one-record-at-a-time procedures, so nothing breaks on an
instance that has not been updated -- it is only slow to browse, which is
easy to miss.  Re-run the whole file rather than parts of it: the
catalog uses the procedures in three groups (listing, per experiment,
whole store) and falls back for each group on its own.

The header of us3_catalog_procs.sql documents the status codes these
procedures answer with and whose records they list.  tests/catalog_smoke.sh
checks them against a scratch database; see tests/README.
