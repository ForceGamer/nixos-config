# fail2ban for the services that face the internet. Each service module adds
# its own jail; this only sets the shared policy. Chosen over CrowdSec because
# it needs nothing fetched at runtime (CrowdSec pulls hub configs and community
# blocklists) and is a native module with a single daemon.
{
  services.fail2ban = {
    enable = true;
    # Home LAN, WireGuard peers and the Claude VM can never be banned, so a
    # local misconfiguration can't lock the operator out.
    ignoreIP = [
      "10.0.0.0/8"
      "172.16.0.0/12"
      "192.168.0.0/16"
    ];
    maxretry = 5;
    bantime = "1h";
    # Repeat offenders stay out longer: 1h, 2h, 4h, ... up to a week.
    bantime-increment = {
      enable = true;
      maxtime = "168h";
    };
  };
}
