# Application Load Balancer + target groups + listener rules.
#
# Not yet implemented in this slice. The next slice adds a single ALB
# with host-based routing (matches the sandbox/notes.md decision),
# covering, for sandbox:
#
#   sandbox.brainkb.org                → UI (port 13000)
#   usermanagement.sandbox.brainkb.org → usermanagement (port 18004)
#   mlservice.sandbox.brainkb.org      → ml_service (port 18007)
#
# When this slice lands it will also add:
# - an ALB security group (aws_security_group.alb)
# - EC2 SG ingress rules allowing traffic from the ALB SG on the app
#   ports (rather than 0.0.0.0/0 as production currently has, per
#   discovery.md).
