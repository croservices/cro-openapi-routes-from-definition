use Cro::HTTP::Client;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::OpenAPI::RoutesFromDefinition;
use Test;

my constant TEST_PORT = 30001;

my $api-doc = q:to/OPENAPI/;
    {
        "openapi": "3.0.0",
        "info": {
            "version": "1.0.0",
            "title": "Cro Test Case"
        },
        "paths": {
            "/some/literals/{value}/more/literals/{value2}/final": {
                "get": {
                    "summary": "Template with mixed values and literal segments",
                    "operationId": "complexTemplate"
                }
            }
        }
    }
    OPENAPI

my $application = openapi $api-doc, {
    operation 'complexTemplate', -> $value1, $value2 {
        content 'text/plain', "Value 1: $value1, Value 2: $value2";
    }
}

my $server = Cro::HTTP::Server.new: :host<0.0.0.0>, :port(TEST_PORT), :$application;
$server.start;
my $uri = "http://localhost:{TEST_PORT}";

{
    my $resp = await Cro::HTTP::Client.get: "$uri/some/literals/16/more/literals/25/final";
    is $resp.status, 200, 'Valid 200 response returned for complex template';
    is await($resp.body-text), 'Value 1: 16, Value 2: 25',
        'Got route parameters as expected';
}

done-testing;
