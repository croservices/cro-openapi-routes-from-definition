use Cro::HTTP::Client;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::OpenAPI::RoutesFromDefinition;
use JSON::Fast;
use Test;

my constant TEST_PORT = 29997;

my $api-doc = q:to/OPENAPI/;
    {
        "openapi": "3.0.0",
        "info": {
            "version": "1.0.0",
            "title": "Cro Test Case"
        },
        "paths": {
            "/pets": {
                "post": {
                    "summary": "Create a pet",
                    "operationId": "createPets",
                    "requestBody": {
                        "required": true,
                        "content": {
                            "application/json": {
                                "schema": {
                                    "$ref": "#/components/schemas/Pet"
                                }
                            }
                        }
                    },
                    "responses": {
                        "201": {
                            "description": "Null response"
                        }
                    }
                }
            },
            "/multipart-pets": {
                "post": {
                    "summary": "Create a pet",
                    "operationId": "createMultipartPets",
                    "requestBody": {
                        "required": true,
                        "content": {
                            "multipart/form-data": {
                                "schema": {
                                    "type": "object",
                                    "properties": {
                                        "data": {
                                            "$ref": "#/components/schemas/Pet"
                                        }
                                    }
                                }
                            }
                        }
                    },
                    "responses": {
                        "201": {
                            "description": "Null response"
                        }
                    }
                }
            }
        },
        "components": {
            "schemas": {
                "Pet": {
                    "type": "object",
                    "required": [
                        "id",
                        "name"
                    ],
                    "properties": {
                        "id": {
                            "type": "integer",
                            "format": "int64"
                        },
                        "name": {
                            "type": "string"
                        },
                        "tag": {
                            "type": "string"
                        }
                    },
                    "additionalProperties": false
                }
            }
        }
    }
    OPENAPI

my $application = openapi $api-doc, {
    operation 'createPets', -> {
        request-body -> (:$id, *%) {
            created "/pets/$id";
        }
    }
    operation 'createMultipartPets', -> {
        request-body -> %d {
            my $json = %d<data>;
            my %data = from-json($json);
            created "/pets/{%data<id>}";
        }
    }
}

my $server = Cro::HTTP::Server.new: :host<0.0.0.0>, :port(TEST_PORT), :$application;
$server.start;
my $uri = "http://127.0.0.1:{TEST_PORT}/pets";
my $multipart-uri = "http://127.0.0.1:{TEST_PORT}/multipart-pets";

{
    my $resp = await Cro::HTTP::Client.post: $uri, :content-type<application/json>,
        :body{ :id(1234), :name('Claire the Cat'), :tag('cute') };
    is $resp.status, 201, 'Valid request with all allowed props gets 201 status response';
    is $resp.header('location'), '/pets/1234', 'Accessed body fine and used it in response';
}

{
    my $resp = await Cro::HTTP::Client.post: $uri, :content-type<application/json>,
        :body{ :id(1235), :name('Claire the Cat') };
    is $resp.status, 201, 'Valid request without optional prop gets 201 status response';
    is $resp.header('location'), '/pets/1235', 'Accessed body fine and used it in response';
}

{
    my $resp = await Cro::HTTP::Client.post: $multipart-uri,
        content-type => 'multipart/form-data',
        body => [
            Cro::HTTP::Body::MultiPartFormData::Part.new(
				name      => 'data',
				headers   => [Cro::HTTP::Header.new(name => 'Content-Type', value => 'application/json')],
				body-blob => '{ "id": 1236, "name": "Claire the Cat" }'.encode
            )
        ];
    is $resp.status, 201, 'Valid Multipart request succeeds';
    is $resp.header('location'), '/pets/1236', 'Accessed body fine and used it in response';
}

throws-like
    {
        await Cro::HTTP::Client.post: $uri
    },
    X::Cro::HTTP::Error,
    response => { .status == 400 },
    'When no body, then 400 error';

throws-like
    {
        await Cro::HTTP::Client.post: $uri, :content-type<text/plain+json>,
            :body{ :id(1234), :name('Claire the Cat') }
    },
    X::Cro::HTTP::Error,
    response => { .status == 400 },
    'When content-type is not in the set of allowed ones, then 400 error';

throws-like
    {
        await Cro::HTTP::Client.post: $uri, :content-type<application/json>,
            :body{ :name('Claire the Cat') }
    },
    X::Cro::HTTP::Error,
    response => { .status == 400 },
    'When required field is missing in body then 400 error';

throws-like
    {
        await Cro::HTTP::Client.post: $uri, :content-type<application/json>,
            :body{ :id(1234), :name('Claire the Cat'), :age(4) }
    },
    X::Cro::HTTP::Error,
    response => { .status == 400 },
    'When unexpected field found in body then 400 error';

$server.stop;

done-testing;
