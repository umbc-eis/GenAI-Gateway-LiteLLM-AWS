###############################################################################
# WAFv2 Web ACL
###############################################################################
resource "aws_wafv2_web_acl" "litellm_waf" {
  name        = "LiteLLMWAF"
  description = "WAF for LiteLLM"
  scope       = "REGIONAL" # or CLOUDFRONT

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "LiteLLMWebAcl"
    sampled_requests_enabled   = true
  }

  # Throttle model listing per source IP. In September-October 2026 a few external IPs
  # sent tens of thousands of /v1/models requests a day, each with a different invalid
  # key. Every attempt wrote a row to LiteLLM_DailyUserSpend (and siblings), which grew
  # the Usage page's 7-day query to 1.1M result rows and crashed it.
  #
  # The limit was set from two weeks of WAF logs: legitimate callers sit far below it,
  # and the key-guessing traffic ran hundreds of times above it. Only /models requests
  # are blocked, so an IP over the limit keeps working for chat and embeddings.
  rule {
    name     = "RateLimit-ModelsList"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = 100
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"

        scope_down_statement {
          or_statement {
            statement {
              byte_match_statement {
                search_string         = "/v1/models"
                positional_constraint = "STARTS_WITH"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "/models"
                positional_constraint = "STARTS_WITH"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "LiteLLMRateLimitModelsList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet-Exclusions"
    priority = 1

    # override_action is required if referencing a rule group
    # - use 'none' if you want to keep the group’s default action 
    # - or 'count' to effectively “disable” or “exclude” from blocking
    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # This is the Terraform equivalent to the "excludedRules" from CloudFormation/CDK:
        # We override the action of these specific sub-rules to avoid them blocking requests.
        rule_action_override {
          name = "NoUserAgent_HEADER"
          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "GenericLFI_BODY"
          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "CrossSiteScripting_BODY"
          action_to_use {
            count {}
          }
        }

        # MCP OAuth clients (Claude Code, Cursor, etc.) register loopback
        # redirect URIs like http://localhost:<port>/callback. The GenericRFI
        # rules flag any parameter containing a ://<ip-or-localhost> URL as a
        # remote-file-inclusion/SSRF attempt and block the OAuth authorize /
        # register calls with a 403. Count instead of block so the flow works.
        rule_action_override {
          name = "GenericRFI_QUERYARGUMENTS"
          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "GenericRFI_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "LiteLLMCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "LiteLLMCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

}
