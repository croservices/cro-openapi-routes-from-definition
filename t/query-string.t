use Cro::HTTP::Client;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::OpenAPI::RoutesFromDefinition;
use Test;

my constant TEST_PORT = 29998;

my $api-doc = q:to/OPENAPI/;
    {
        "openapi": "3.0.0",
        "info": {
            "version": "1.0.0",
            "title": "Cro Test Case"
        },
        "paths": {
            "/pets/search": {
                "parameters": [
                    {
                        "name": "limit",
                        "in": "query",
                        "required": false,
                        "schema": {
                            "type": "integer"
                        }
                    }
                ],
                "get": {
                    "summary": "Search for gets",
                    "operationId": "searchPets",
                    "parameters": [
                        {
                            "name": "type",
                            "in": "query",
                            "required": true,
                            "schema": {
                                "type": "string",
                                "enum": ["dog", "cat", "parrot"]
                            }
                        }
                    ],
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

throws-like
    {
        openapi $api-doc, {
            operation 'searchPets', -> :$type, :$no-such, :$limit {
            }
        }
    },
    X::Cro::OpenAPI::RoutesFromDefinition::UnexpectedQueryPrameter,
    operation => 'searchPets',
    parameter => 'no-such';

done-testing;
