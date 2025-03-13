## SPAM GUARD ##
This is a tool to automate ham and spam learning on incoming (and moved ) emails
its been developed on a setup utilizing postfix, dovecot, and spamassassin (via procmail)
it sets up watches for all user mailboxes and learns every incoming mail as ham, 
except for those in the spam folder, those are obviously learned as spam
on moving emails to spam folder those will be learned as spam as well 
on moving emails from spam. to any other folder those will be learned as ham
exceptions are Trash, Draft and Sent folders those arent learned at all.
it does scan for new mailboxes every 6 hours (configurable by setting UPDATE_INTERVAL in /etc/spamguard/spamguard_config)
debug level can be set in the same file
it does set up a cronjob that will run sa-learn --rebuild every sunday at midnight
it will log to /var/log/spamguard.log according to the chosen log level and rotate logfile daily

## this is beta software at best ##
thats why i am not providing prebuildt packages for it
## dont use it unless you know exactly what its doing, i'll take absolutely no responsibility ##



Structure and code are intended to be packed as a debian package and installed that way
then it will run as a systemd service 

its been developed on a small machine running ubuntu server 20.04 (was updated to 22.04 during development)
and thats all its ever been tested on

it's released under MIT License, so do whatever you like with it
i'd appreciate your contribution. 
It does fullfill my needs at the moment, even if i think about switching to user based databases later.
If you have better knowledge of shell scripting than i do your improvements are very welcome.


