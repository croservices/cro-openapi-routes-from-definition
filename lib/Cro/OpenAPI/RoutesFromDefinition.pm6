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
            has Str $.path-template is required;
            has @!template-segments;
            has OpenAPI::Model::Path $.path is required;
            has OpenAPI::Model::Operation $.operation is required;
            has &.implementation;
            has Bool $.allow-invalid;

            method TWEAK() {
                if $!path-template.starts-with('/') {
                    @!template-segments = $!path-template.substr(1).split('/');
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
        }

        has OpenAPI::Model::OpenAPI $.model;
        has Operation %.operations-by-id;

        submethod TWEAK() {
            for $!model.paths -> $paths {
                for flat $paths.keys Z $paths.values -> Str $path-template, $path {
                    for <get put post delete options head patch trace> -> $method {
                        with $path."$method"() -> $operation {
                            %!operations-by-id{$operation.operation-id} = Operation.new:
                                :$path-template, :$path, :$operation;
                        }
                    }
                }
            }
        }

        method add-handler(Str $method, &) {
            die X::Cro::OpenAPI::RoutesFromDefinition::InvalidUse.new(what => $method.lc);
        }

        method include(@, Cro::HTTP::Router::RouteSet) {
            die X::Cro::OpenAPI::RoutesFromDefinition::InvalidUse.new(what => 'include');
        }

        method delegate(@, Cro::Transform) {
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
