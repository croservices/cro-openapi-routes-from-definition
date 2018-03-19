use Cro::HTTP::Request;
use Cro::HTTP::Response;
use OpenAPI::Schema::Validate;

class X::Cro::OpenAPI::RoutesFromDefinition::CheckFailed is Exception {
    has Cro::HTTP::Message $.http-message is required;
    has Str $.reason is required;
    method message() {
        my $what = $!http-message ~~ Cro::HTTP::Request ?? 'request' !! 'response';
        "OpenAPI $what validation failed: $!reason"
    }
}

package Cro::OpenAPI::RoutesFromDefinition {
    role Checker {
        method check(Cro::HTTP::Message $m, Any $body --> Nil) { ... }
        method requires-body(--> Bool) { ... }
    }

    class AllChecker does Checker {
        has Checker @.checkers;
        method check(Cro::HTTP::Message $m, $body --> Nil) {
            .check($m, $body) for @!checkers;
        }
        method requires-body(--> Bool) {
            any(@!checkers>>.requires-body)
        }
    }

    class BodyChecker does Checker {
        has Bool $.write;
        has Bool $.read;
        has Bool $.required;
        has %!content-type-schemas;
        submethod TWEAK(:%content-schemas --> Nil) {
            for %content-schemas.kv -> $type, $schema {
                %!content-type-schemas{$type.fc} = $schema
                    ?? OpenAPI::Schema::Validate.new(:$schema)
                    !! Nil;
            }
        }
        method check(Cro::HTTP::Message $m, $body --> Nil) {
            if $m.header('content-type') -> $content-type {
                if %!content-type-schemas{$content-type.fc}:exists {
                    with %!content-type-schemas{$content-type.fc} {
                        .validate($body, :$!read, :$!write);
                        CATCH {
                            when X::OpenAPI::Schema::Validate::Failed {
                                die X::Cro::OpenAPI::RoutesFromDefinition::CheckFailed.new(
                                    http-message => $m,
                                    reason => "validation of '$content-type' schema failed " ~
                                        "at $_.path(): $_.reason()"
                                );
                            }
                        }
                    }
                }
                else {
                    die X::Cro::OpenAPI::RoutesFromDefinition::CheckFailed.new(
                        http-message => $m,
                        reason => "content type '$content-type' is not allowed"
                    );
                }
            }
            elsif $!required {
                die X::Cro::OpenAPI::RoutesFromDefinition::CheckFailed.new(
                    http-message => $m,
                    reason => "a message body is required"
                );
            }
        }
        method requires-body(--> Bool) {
            True
        }
    }

    class QueryStringChecker does Checker {
        has %!required;
        has %!expected;
        has %!schemas;
        method TWEAK(:@parameters) {
            for @parameters {
                %!expected{.name} = True;
                %!required{.name} = True if .required;
                if .schema -> $schema {
                    %!schemas{.name} = OpenAPI::Schema::Validate.new(:$schema);
                }
            }
        }
        method check(Cro::HTTP::Message $m, $ --> Nil) {
            my %required-unseen = %!required;
            for $m.query-hash.kv -> $name, $value {
                unless %!expected{$name}:exists {
                    die X::Cro::OpenAPI::RoutesFromDefinition::CheckFailed.new(
                        http-message => $m,
                        reason => "unexpected query string parameter '$name'"
                    );
                }
                %required-unseen{$name}:delete;
                with %!schemas{$name} {
                    my $result = .validate($value);
                    unless $result {
                        $result = .validate(val($value));
                    }
                    unless $result {
                        given $result.exception {
                            die X::Cro::OpenAPI::RoutesFromDefinition::CheckFailed.new(
                                http-message => $m,
                                reason => "validation of '$name' query string parameter " ~
                                          "schema failed at $_.path(): $_.reason()"
                            );
                        }
                    }
                }
            }
            if %required-unseen {
                die X::Cro::OpenAPI::RoutesFromDefinition::CheckFailed.new(
                    http-message => $m,
                    reason => "missing required query string parameter '{%required-unseen.keys[0]}'"
                );
            }
        }
        method requires-body(--> Bool) {
            False
        }
    }

    class ResponseChecker does Checker {
        has %.checker-by-code;
        method check(Cro::HTTP::Message $m, $body --> Nil) {
            with %!checker-by-code{$m.status} {
                .check($m, $body);
            }
            elsif $m.status != 500 {
                die X::Cro::OpenAPI::RoutesFromDefinition::CheckFailed.new(
                    http-message => $m,
                    reason => "this response may not produce status $m.status()"
                );
            }
        }
        method requires-body(--> Bool) {
            so any(%!checker-by-code.values).requires-body
        }
    }

    class PassChecker does Checker {
        method check($, $ --> Nil) {
            # Always accept
        }
        method requires-body(--> Bool) {
            False
        }
    }
}
