# Product & Engineering Recommendations

Based on your investigation of the debug scenario, provide recommendations for improving the platform.

## Monitoring Improvements

<!-- What monitoring should be added to detect this class of issue earlier? -->

- Link alerts to open change tickets automatically - this incident would have been resolved in minutes
- Alert on MTU changes to `eno1`, not just upload failures
- Add a large-packet health check - small packets passed throughout and masked the problem
- 15 minutes from CRITICAL alert to investigation is too slow; target should be 5 minutes

## Automated Detection

<!-- How could the system automatically detect and potentially self-heal from this type of failure? -->
- Add MTU validation to `healthcheck.sh` - expected value is known, deviation should page immediately
- Alert on VPN throughput drop, not just tunnel up/down status
- Page on 3+ tunnel flaps within 30 minutes - that pattern had no alert at all

## Platform Changes

<!-- What changes to the product/platform would reduce the likelihood or impact of similar incidents? -->
- Require a diff review before applying netplan changes - wrong interface was targeted because nobody checked what would actually change
- Declare expected MTU per interface in config management so drift is detectable
- Clamp MSS on the VPN tunnel so a misconfiguration degrades gracefully rather than taking the tunnel down entirely


## Edge Device Improvements

<!-- What improvements to edge device management would help? Consider:
- Configuration management
- Change control
- Automated validation
-->

- Split netplan into per-interface files - a camera VLAN change shouldn't be in the same file as the WAN interface
- Validate connectivity after any network change before returning success
- Alert on upload queue depth earlier - the device knew at 08:20, didn't alert until 08:30
