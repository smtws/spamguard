# SpamGuard

SpamGuard is a tool designed to automate the learning process of distinguishing between spam and legitimate (ham) emails. Developed for systems utilizing Postfix, Dovecot, and SpamAssassin (via Procmail), SpamGuard enhances spam detection accuracy by continuously adapting to user-specific email management behaviors.

## Features

- **Automated Learning**:
  - Classifies every incoming email as ham, except those directed to the spam folder, which are learned as spam.
  - Identifies emails moved to the spam folder as spam and those moved from the spam folder to any other folder as ham.

- **Folder Exclusions**:
  - Excludes specific folders—Trash, Drafts, and Sent—from the learning process to prevent misclassification.

- **Mailbox Scanning**:
  - Scans for new mailboxes every six hours (configurable via the `UPDATE_INTERVAL` setting in `/etc/spamguard/spamguard_config`).

- **Rebuild Process**:
  - Sets up a cron job to run `sa-learn --rebuild` every Sunday at midnight to maintain the efficiency of the learning process.

- **Logging**:
  - Logs activities to `/var/log/spamguard.log` based on the configured debug level, with daily log rotation.

## Installation

SpamGuard is structured to be packaged as a Debian package and installed accordingly, operating as a systemd service. It has been developed and tested on a machine running Ubuntu Server 20.04, which was updated to 22.04 during development. **It was never tested on any other platform**

***Note***: **Pre-built packages are not provided due to the beta status of the software. Users are advised to build and install the package manually, ensuring they understand the installation process and functionality.**

### Building and Installing the Debian Package

To build and install the SpamGuard Debian package, follow these steps:

1. **Install Required Dependencies**:

   Ensure you have the necessary tools for building Debian packages:

   ```bash
   sudo apt-get update
   sudo apt-get install build-essential devscripts debhelper
   ```


2. **Clone the Repository**:

   Clone the SpamGuard repository to your local machine:

   ```bash
   git clone https://github.com/smtws/spamguard.git
   cd spamguard
   ```


3. **Build the Package**:

   Use `debuild` to build the Debian package:

   ```bash
   debuild -us -uc
   ```


   This command will create a `.deb` package in the parent directory.

4. **Install the Package**:

   Navigate to the parent directory and install the package using `dpkg`:

   ```bash
   cd ..
   sudo dpkg -i spamguard_*.deb
   ```


5. **Start and Enable the Service**:

   After installation, start the SpamGuard service and enable it to run at boot:

   ```bash
   sudo systemctl start spamguard
   sudo systemctl enable spamguard
   ```


For more detailed instructions on building Debian packages, refer to the [Debian New Maintainers' Guide](https://www.debian.org/doc/manuals/maint-guide/build.en.html).

## Configuration

The primary configuration file is located at `/etc/spamguard/spamguard_config`. Key configurable parameters include:

- **`UPDATE_INTERVAL`**: Determines the frequency (in hours) at which SpamGuard scans for new mailboxes.

- **`DEBUG_LEVEL`**: Sets the verbosity of logging information.

Adjust these settings as needed to suit your server environment and preferences.

## Contributing

Contributions to SpamGuard are welcome and appreciated! To contribute:

1. Fork the repository.

2. Create a new branch for your feature or bugfix.

3. Make your changes and commit them with clear messages.

4. Push your changes to your fork.

5. Submit a pull request to the main repository.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Support

If you find SpamGuard useful, please consider giving the project a ⭐ on GitHub. For support or questions, open an issue in the repository.
