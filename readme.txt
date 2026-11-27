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

verify_model_permission (changed behaviour)

verify_model_permission (us3_model_procs.sql), which update_model,
get_model_info, delete_model, new_noise and update_noise use, matches the
model's modelPerson row against the caller once the caller has logged
in.  It matched it against the @US3_ID of the previous login on the
connection: on a new connection the model's owner was refused (201)
unless something had logged in first, as UltraScan3 does when it
connects, and after another person's login on the same connection the
caller was let in to that person's models.


timestamp2UTC (changed behaviour)

timestamp2UTC (us3_procedures.sql), through which the catalog
procedures and many others report TIMESTAMP columns as UTC, converts
with the offset in force at the time given, in the connection's time
zone (UNIX_TIMESTAMP(), which applies the zone's daylight-saving rules
without the time zone tables).  It used the time zone tables, when
loaded, from the server's global zone whatever the connection's zone,
and otherwise the offset of the moment of the last login: a summer time
read in winter (or the other way round) came out an hour off, and on a
connection that had not logged in yet the result was NULL.  Times
outside the TIMESTAMP range are converted as before.
