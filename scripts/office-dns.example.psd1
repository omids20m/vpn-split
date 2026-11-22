# Copy to office-dns.psd1 (same folder as office-dns-permit.ps1) and fill in.
# office-dns.psd1 is git-ignored, so the real values stay out of the repo.
@{
  Resolvers = @('10.0.0.2', '10.0.0.3')   # internal DNS servers announced by the Fortigate (IPv4)
  DnsSuffix = @('office-domain.example')  # internal DNS suffixes (one or more); only names under them go to the resolvers
  TestHost  = 'intranet.office-domain.example'   # optional: name looked up by -Status
}
