# Default Sieve script, installed for each mailbox when Cyrus first creates it
# (autocreate_sieve_script). Same rule as the old snap mailserver
# (lib/mailserver/maint/spam.sieve). Users can replace it with their own.
require ["fileinto"];

if header :contains "X-Spam-Flag" "YES" {
    fileinto "Spam-maybe";
}
