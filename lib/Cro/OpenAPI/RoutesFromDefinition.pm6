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

module Cro::OpenAPI::RoutesFromDefinition {
    class OperationSet is Cro::HTTP::Router::RouteSet {
        my class Operation {
            has Str $.path-template;
            has OpenAPI::Model::Path $.path;
            has OpenAPI::Model::Operation $.operation;
            has &.implementation is rw;
            has Bool $.allow-invalid is rw;
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
                .implementation = &implementation;
                .allow-invalid = $allow-invalid;
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
