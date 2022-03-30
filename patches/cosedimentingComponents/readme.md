# How to use
1. Make sure you make a backup before you execute the script (just in case...)
2. run the `cosedimentingComponents.sql`
3. Check if everything worked with:

    1. `SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_NAME like '%cosed%'` -> should return `cosedComponent` & `buffercosedlink`

    2. `SELECT count(*) FROM cosedComponent` -> should return `94`

    3. `SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_TYPE='PROCEDURE' and 
ROUTINE_NAME like '%cosed%' or ROUTINE_NAME in ('delete_buffer','delete_buffer_components')` -> should return 6 names