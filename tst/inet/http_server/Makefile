#
# @file Makefile
# @version 0.4.0
#
# @section License
# Copyright (C) 2016, Erik Moqvist
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# This file is part of the Simba project.
#

NAME = server_suite
VERSION = 0.0.1
BOARD ?= linux

SRC += socket_stub.c

SIMBA_ROOT = ../../..

INET_SRC = \
	http_server.c \
	http_websocket_server.c

include $(SIMBA_ROOT)/make/app.mk