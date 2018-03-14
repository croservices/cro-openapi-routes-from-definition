use Cro::HTTP::Auth;
use Cro::HTTP::Router;
use OpenAPI::Model;

class X::Cro::OpenAPI::RoutesFromDefinition::InvalidUse is Exception {
    has Str $.what is required;
    method message() {
        "Using '$!what' in an `openapi` block is not allowed; use `operation`"
    }
}

class X::Cro::OpenAPI::RoutesFromDefinition::UnimplementedOperations is Exception {
    has @.operations;
    method message() {
        "The following operations are unimplemented: @!operations.join(', ')"
    }
}

class X::Cro::OpenAPI::RoutesFromDefinition::UnspecifiedOperation is Exception {
    has Str $.operation is required;
    method message() {
        "The operation '$!operation' does not exist in the OpenAPI document"
    }
}

class X::Cro::OpenAPI::RoutesFromDefinition::WrongPathSegmentCount is Exception {
    has Str $.operation is required;
    has Str $.path-template is required;
    has Int $.expected is required;
    has Int $.got is required;
    method message() {
        "The operation '$!operation' has path '$!path-template'.\n" ~
        "The implementation should take $!expected route segment(s), but has $!got."
    }
}

module Cro::OpenAPI::RoutesFromDefinition {
    class OperationSet is Cro::HTTP::Router::RouteSet {
        my class Operation {
            has Str $.method is required;
            has Str $.path-template is required;
            has @!template-segments;
            has @!prefix-parts;
            has OpenAPI::Model::Path $.path is required;
            has OpenAPI::Model::Operation $.operation is required;
            has &.implementation;
            has Bool $.allow-invalid;

            method TWEAK() {
                if $!path-template.starts-with('/') {
                    @!template-segments = $!path-template.substr(1).split('/');
                    for @!template-segments {
                        state $seen-non-literal = False;
                        if /^'{'.+'}'$/ {
                            $seen-non-literal = True;
                        }
                        elsif $seen-non-literal {
                            die "Non-literal route segment not at start of path template is NYI";
                        }
                        else {
                            push @!prefix-parts, $_;
                        }
                    }
                }
                else {
                    die "Invalid path template '$!path-template' (must start with '/')";
                }
            }

            method set-implementation(&!implementation, $!allow-invalid) {
                my @pos = &!implementation.signature.params.grep(!*.named);
                @pos.shift if @pos[0] ~~ Cro::HTTP::Auth;
                my $got = @pos.elems;
                my $expected = self!required-path-segments();
                if $got != $expected {
                    die X::Cro::OpenAPI::RoutesFromDefinition::WrongPathSegmentCount.new(
                        :operation($!operation.operation-id),
                        :$!path-template, :$expected, :$got
                    );
                }
            }

            method !required-path-segments() {
                @!template-segments.grep(/^'{' .+ '}'$/).elems
            }

            method prefix-parts { @!prefix-parts }
        }

        my class OperationHandler does Cro::HTTP::Router::RouteSet::Handler {
            has Str $.method;
            has &.implementation;

            method copy-adding(:@prefix, :@body-parsers!, :@body-serializers!, :@before!, :@after!) {
                self.bless:
                    :$!method, :&!implementation,
                    :prefix[flat @prefix, @!prefix],
                    :body-parsers[flat @!body-parsers, @body-parsers],
                    :body-serializers[flat @!body-serializers, @body-serializers],
                    :before[flat @before, @!before],
                    :after[flat @!after, @after]
            }

            method signature() {
                &!implementation.signature
            }

            method !invoke-internal(Cro::HTTP::Request $request, Capture $args --> Promise) {
                my $*CRO-ROUTER-REQUEST = $request;
                my $response = my $*CRO-ROUTER-RESPONSE := Cro::HTTP::Response.new(:$request);
                self!add-body-parsers($request);
                self!add-body-serializers($response);
                start {
                    {
                        &!implementation(|$args);
                        CATCH {
                            when X::Cro::HTTP::Router::NoRequestBodyMatch {
                                $response.status = 400;
                            }
                            when X::Cro::BodyParserSelector::NoneApplicable {
                                $response.status = 400;
                            }
                            default {
                                .note;
                                $response.status = 500;
                            }
                        }
                    }
                    $response.status //= 204;
                    # Close push promises as we don't get a new ones
                    $response.close-push-promises();
                    $response
                }
            }

            method invoke(Cro::HTTP::Request $request, Capture $args) {
                if @!before || @!after {
                    my $current = supply emit $request;
                    my %connection-state{Mu};
                    $current = self!append-middleware($current, @!before, %connection-state);
                    my $response = supply whenever $current -> $req {
                        whenever self!invoke-internal($req, $args) {
                            emit $_;
                        }
                    }
                    return self!append-middleware($response, @!after, %connection-state);
                } else {
                    return self!invoke-internal($request, $args);
                }
            }
        }

        has OpenAPI::Model::OpenAPI $.model;
        has Operation %.operations-by-id;

        submethod TWEAK() {
            for $!model.paths -> $paths {
                for flat $paths.kv -> Str $path-template, $path {
                    for <get put post delete options head patch trace> -> $method {
                        with $path."$method"() -> $operation {
                            %!operations-by-id{$operation.operation-id} = Operation.new:
                                :method($method.uc), :$path-template, :$path, :$operation;
                        }
                    }
                }
            }
        }

        method add-handler(Str $method, &) {
            die X::Cro::OpenAPI::RoutesFromDefinition::InvalidUse.new(what => $method.lc);
        }

        method add-include(@, Cro::HTTP::Router::RouteSet) {
            die X::Cro::OpenAPI::RoutesFromDefinition::InvalidUse.new(what => 'include');
        }

        method add-delegate(@, Cro::Transform) {
            die X::Cro::OpenAPI::RoutesFromDefinition::InvalidUse.new(what => 'delegate');
        }

        method add-operation(Str $operation-id, &implementation, Bool $allow-invalid) {
            with %!operations-by-id{$operation-id} {
                .set-implementation(&implementation, $allow-invalid);
            }
            else {
                die X::Cro::OpenAPI::RoutesFromDefinition::UnspecifiedOperation.new(
                    operation => $operation-id
                );
            }
        }

        method definition-complete(:$ignore-unimplemented --> Nil) {
            self!check-unimplemented() unless $ignore-unimplemented;
            for %!operations-by-id.values {
                if .implementation {
                    self.handlers.push(OperationHandler.new(
                        :implementation(.implementation), :method(.method),
                        :prefix(.prefix-parts), :@.before, :@.after,
                        :@.body-parsers,  :@.body-serializers
                    ));
                }
            }
            callsame();
        }

        method !check-unimplemented() {
            my @operations;
            for %!operations-by-id.kv -> $id, $operation {
                push @operations, $id without $operation.implementation;
            }
            if @operations {
                die X::Cro::OpenAPI::RoutesFromDefinition::UnimplementedOperations.new:
                    :operations(@operations.sort);
            }
        }
    }

    multi openapi(IO:D $handle, &block, *%options) is export {
        openapi($handle.slurp, &block, |%options);
    }

    multi openapi(Str:D $openapi-document, &implementation,
                  Bool() :$ignore-unimplemented = False,
                  Bool() :$implement-examples = False,
                  Bool() :$validate-responses = True) is export {
        my $model = $openapi-document ~~ /^\s*'{'/
            ?? OpenAPI::Model.from-json($openapi-document)
            !! OpenAPI::Model.from-yaml($openapi-document);
        my $*CRO-ROUTE-SET = OperationSet.new(:$model);
        implementation();
        $*CRO-ROUTE-SET.definition-complete(:$ignore-unimplemented);
        return $*CRO-ROUTE-SET;
    }

    multi operation(Str:D $operation-id, &implementation,
                    Bool() :$allow-invalid = False) is export {
        given $*CRO-ROUTE-SET {
            when OperationSet {
                .add-operation($operation-id, &implementation, $allow-invalid);
            }
            default {
                die "Can only use `operation` inside of an `openapi` block";
            }
        }
    }
}
