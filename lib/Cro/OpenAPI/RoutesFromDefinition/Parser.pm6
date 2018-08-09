use OpenAPI::Styles;

class X::Cro::OpenAPI::RoutesFromDefinition::ParseFailed is Exception {
    # has Cro::HTTP::Message $.http-message is required;
    has Str $.reason is required;
    # has Bool $.bad-path = False;
    method message() {
        "Parsing failed"
    }
}

my class FakeHeader {
    has $.name;
    has $.value;
}

my role Accessor {
    has @!parsed-headers;

    method header($name) {
        @!parsed-headers.grep(*.name eq $name).first.value;
    }

    method headers() {
        @!parsed-headers;
    }

    method set-parsed-headers(@!parsed-headers) {}
}

class Cro::OpenAPI::RoutesFromDefinition::Parser {
    has %!styles = matrix => OpenAPI::Styles::Matrix,
      label => OpenAPI::Styles::Matrix,
      form => OpenAPI::Styles::Form,
      simple => OpenAPI::Styles::Simple,
      spaceDelimited => OpenAPI::Styles::SpaceDelimited,
      pipeDelimited => OpenAPI::Styles::PipeDelimited,
      deepObject => OpenAPI::Styles::DeepObject;

    # TODO smarter heuristic here
    has %!types = integer => Int,
      string => Str,
      array => Array,
      object => Hash;

    method parse($request, $operation) {
        my @headers;
        for $operation.parameters -> $parameter {
            given $parameter.in {
                when 'header' {
                    my $name = $parameter.name;
                    next unless $request.has-header($name);

                    my $value = from-openapi-style(%!styles{$parameter.style},
                                                   $request.header($name),
                                                   explode => $parameter.explode,
                                                   name => $name,
                                                   type => %!types{$parameter.schema<type>});
                    
                    $value = self!coerce-types($value, $parameter.schema);
                    my $fake = FakeHeader.new(:$name, :$value);
                    @headers.append: $fake;
                    $request.remove-header: $parameter.name;
                }
                default {
                    die 'NYI';
                }
            }
        };
        @headers.append($_) for $request.headers;
        $request does Accessor;
        $request.set-parsed-headers(@headers);
        $request;
    }

    method !coerce-types($value, $schema) {
        my $outer-type = $schema<type>;
        given $outer-type {
            when 'string' {
                return $value.Str;
            }
            when 'array' {
                my $type = %!types{$schema<items><type>}.^name;
                my @array = $value.Array;
                @array .= map(*."$type"());
                return @array;
            }
        }
    }
}
