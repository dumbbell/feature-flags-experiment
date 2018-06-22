PROJECT = feature_flags
PROJECT_DESCRIPTION = Experiments with feature flags
PROJECT_MOD = feature_flags_app

define PROJECT_ENV
[
	    {proto, v1}
	  ]
endef

# FIXME: Use erlang.mk patched for RabbitMQ, while waiting for PRs to be
# reviewed and merged.

ERLANG_MK_REPO = https://github.com/rabbitmq/erlang.mk.git
ERLANG_MK_COMMIT = rabbitmq-tmp

include erlang.mk
