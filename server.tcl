#!/usr/bin/env tclsh
# Copyright © 2025 Pedro de Medeiros (pedro.medeiros at gmail.com)

# Define the port to listen on
set port 9756

# Function to handle client connections
proc handle_client {client_socket client_address client_port} {
    puts "Connection from $client_address:$client_port"

    # Configure the socket for non-blocking I/O
    fconfigure $client_socket -blocking 0 -buffering line

    # Set up a fileevent to handle incoming data
    fileevent $client_socket readable [list read_from_client $client_socket]

    # Send a welcome message to the client
    puts $client_socket "Welcome to the server! Send me a message."
    flush $client_socket
}

# Function to read data from the client
proc read_from_client {client_socket} {
    if {[eof $client_socket]} {
        puts "Client disconnected."
        close $client_socket
        return
    }

    # Read a line of data from the client
    if {[gets $client_socket line] >= 0} {
        puts "Received from client: $line"

        # Check if the message is "quit"
        if {$line eq "quit"} {
            puts "Received 'quit' command. Shutting down server..."
            close $client_socket
            shutdown_server
            return
        }

        # Send a response back to the client
        puts $client_socket "You said: $line"
        flush $client_socket
    }
}

proc start {} {
    variable port

    # Create a server socket
    set server_socket [socket -server handle_client $port]
    puts "Server listening on port $port..."

    # Enter the event loop to handle connections (not necessary in OpenMSX)
    #vwait forever
}

