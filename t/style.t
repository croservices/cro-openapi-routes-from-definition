use Cro::HTTP::Client;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::OpenAPI::RoutesFromDefinition;
use Test;

my constant TEST_PORT = 30008;

my $api-doc = q:to/OPENAPI/;
    {
        "openapi": "3.0.0",
        "info": {
            "version": "1.0.0",
            "title": "Cro Test Case"
        },
        "paths": {
            "/home": {
                "get": {
                    "summary": "Test incoming cookie validation",
                    "operationId": "home",
                    "parameters": [
                        {
                            "name": "token",
                            "in": "header",
                            "description": "token to be passed as a header",
                            "required": true,
                            "schema": {
                                "type": "array",
                                "items": {
                                    "type": "integer",
                                    "format": "int64"
                                }
                            },
                            "style": "simple"
                        }
                    ]
                }
            }
        }
    }
    OPENAPI

my $application = openapi $api-doc, {
    operation 'home', -> :$token! is header {
        content 'text/plain', "Token: {$token.join('&')}";
    }
}

my $server = Cro::HTTP::Server.new: :host<0.0.0.0>, :port(TEST_PORT), :$application;
$server.start;
my $uri = "http://127.0.0.1:{TEST_PORT}";

{
    my $resp = await Cro::HTTP::Client.get: "$uri/home",
        headers => [token => "1,2,3,4,5"];
    is $resp.status, 200, 'Valid 200 response is returend when both cookies sent';
    is await($resp.body-text), 'Token 1&2&3&4&5',
       'Got token as expected';
}

$server.stop;

done-testing;