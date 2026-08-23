<h1>After-e-</h1>

**after -e-** is a self-hosted personal-cloud stack: a coordinated deployment of
Authentik, Nextcloud, Stalwart, Immich, Vaultwarden, and Roundcube. after -e- is 
the series of shell scripts which perform the installation of these projects,
automate connections and initial configurations where possible. It is a spiritual
successor to the `/e/Cloud` self-hosting stack — a departure from it, not a fork
of it. After -e- is built around a single identity provider and a goal of enabling 
a longer service life while still aiming to provide drop-in functionality with
mobile phones running /e/OS, as well as iodeOS, LineageOS, and GrapheneOS where
possible.

**after -e-** seeks to build upon the design tenets and functionality of /e/Cloud
with the following changes:
  - Use of stock Docker images of other open source projects, ensuring better
  overall continuity, better service life, and more effective troubleshooting
  via Google searches and AI queries.
  - Limiting project to shell scripts, .conf files, and similar limits, improving
  readability, forking, and maintenance.
  - Simplified installation process with the goal of reducing the technical
  acumen required for deployment.
  - Tiered installation options to enable use on smaller VPS/VM instances, while
  also allowing greater capabilities for those with greater resource allocations.
  -  Use of Authentik as an SSO provider with both LDAP and ODIC, with all scripts
  integrating with a single identity.

<h2>AI disclosure:</h2>
The scripts themselves were written by Anthropic Claude; my ability to write 
shell scripts is very limited. However, all QA is performed directly with
human oversight; no AI system is given direct access to this repository. All
functionality is verified by human verification before upload. Documentation will
likely be a combination of human and AI writing; effort will be put into noting
any documentation which was AI generated.

For more information, read the (AI generated) ARCHITECTURE.md file.

NO WARRANTY OR SUPPORT GUARANTEE IS EXPRESSED OR IMPLIED; I AM NOT RESPONSIBLE
FOR YOUR LOST DATA, MISSING EMAILS, BOTCHED INSTALL ATTEMPT, OR THERMONUCLEAR WAR.
THIS PROJECT IS DEPENDENT UPON UPSTREAM PROJECTS WHICH THEMSELVES HAVE THEIR OWN
LICENSES TO WHICH YOU MUST AGREE, AND WHICH MAY DISCONTINUE THEIR EXISTENCE AT
ANY TIME. YOU ARE CHOOSING TO SELF-HOST YOUR DATA AND ACCEPT BOTH THE FREEDOM AND 
RESPONSIBILITY WHICH COMES WITH DOING SO.

<h2>SYSTEM REQUIREMENTS:</h2>
- Debian 12/13 were tested; Ubuntu and other Debian derivatives may work, but are not
checked in QA.
- 2-4 CPU cores should be sufficient for up to ten users and dependent on whether 
Immich's Machine Learning capabilities are added.
- 4-16GB RAM, depending on installed tier and desired responsiveness
- 20GB system volume + larger volume for photos/files/mail
- One publicly addressable IPv4 address
- One domain name

<h2>SIMPLIFIED INSTALLATION INSTRUCTIONS:</h2>

1. Prerequisite Setup:

  a. spin up a VPS instance, VM, or other such install destination.
  
  b. ensure you have SSH access, as well as port forwards for 80, 443, 465, and 993.
  
  c. ensure you have access to make A records and CNAME records with your registrar.
  
  d. it is strongly recommended to acquire an account with Mailgun, Mailjet, or SMTP2Go.

2. Upload contents of this Github repo to /mnt/aftere. chmod +x *.sh .

3. run prereq.sh .

4. run dns-setup.sh . This script will provide DNS values; make the prescribed entries.

5. run init.sh . This step will ask most of the setup questions, and install when done.

6. run stalwart-provision.sh . This step gets the e-mail server functional.

7. run postinstall-nextcloud.sh . This step gets Nextcloud syncing data.

8. run newuser.sh and create a new user account by answering its questions.

9. go to https://webmail.yourdomain.com; log in with those credentials to create the mailbox.

10. go to https://yourdomain.com; log in with the same credentials to create the Nextcloud acct.


<h3>PRESENT STATE OF PROJECT IS ALPHA.</h3>
--Stalwart Mail, Authentik, and Nextcloud are known working, complete with mail traversal.
--Other projects (Immich, Vaultwarden) have not been linked to Authentik yet.
--Not every possible permutation of init.sh has been tested, though most have.
--Testing with /e/OS has been done on a new phone with no data; no migration procedures exist yet.
