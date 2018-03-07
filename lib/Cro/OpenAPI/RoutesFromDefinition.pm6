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

module Cro::OpenAPI::RoutesFromDefinition {
    class OperationSet is Cro::HTTP::Router::RouteSet {
        has OpenAPI::Model::OpenAPI $.model;

        method add-handler(Str $method, &) {
            die X::Cro::OpenAPI::RoutesFromDefinition::InvalidUse.new(what => $method.lc);
        }

        method include(@, Cro::HTTP::Router::RouteSet) {
            die X::Cro::OpenAPI::RoutesFromDefinition::InvalidUse.new(what => 'include');
        }

        method delegate(@, Cro::Transform) {
            die X::Cro::OpenAPI::RoutesFromDefinition::InvalidUse.new(what => 'delegate');
        }

        method definition-complete(:$ignore-unimplemented --> Nil) {
            self!check-unimplemented() unless $ignore-unimplemented;
        }

        method !check-unimplemented() {
            my @operations;
            for $!model.paths -> $paths {
                for $paths.values -> $path {
                    for <get put post delete options head patch trace> -> $method {
                        with $path."$method"() {
                            with .operation-id {
                                push @operations, $_;
                            }
                        }
                    }
                }
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
        !!!
    }
}
