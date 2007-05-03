# HttpdWorker - Httpd Protocol worker thread

# TODO: armour all [chan event]s
package require Debug

#puts stderr "Starting Httpd Worker [::thread::id]"
interp bgerror {} bgerror
proc bgerror {error eo} {
    Debug.error {Thread [::thread::id]: $error ($eo)}
    if {[dict get $eo -code] == 1} {
	disconnect $error $eo
    }
}

#puts stderr "Thread: [::thread::id]";
interp alias {} armour {} string map {& &amp; < &lt; > &gt; \" &quot; ' &#39;}

# arrange gzip Transfer Encoding
if {![catch {package require zlib}]} {
    variable te_encodings {gzip}
} else {
    variable te_encodings {}
}
set te_encodings {}	;# uncomment to stop gzip transfers

package require WubUtils
package require Debug
Debug off url
Debug off http 1
Debug off cookies
Debug off socket 1

package require Url
package require Http
package require Cookies

if {0} {
    # some utility/debugging code to track shimmering
    package require tweezer
    proc monitor {var} {
	upvar 1 $var v
	trace add variable v {write read} ::shimmer
    }
    proc unmonitor {var} {
	upvar 1 $var v
	catch {trace remove variable v {write read} ::shimmer}
    }

    proc shimmer {var name2 op} {
	upvar $var v
	if {[info exists v]} {
	    puts stderr "$var shimmers to: [tweezer type $v]"
	}
    }
}

variable request ""	;# dict containing request read
#monitor request	;# monitor request shimmering

variable sock -1		;# socket being supervised by this thread
variable transaction -1	;# transaction count for current connection
variable generation 0	;# worker/connection association generation

# limits on header size
variable maxline 2048	;# max request line length
variable maxfield 4096	;# max request field length
variable maxhead 1024	;# maximum number of header lines
variable maxurilen 1024	;# maximum URI length
variable maxentity -1		;# maximum entity size

package require Timer
Timer txtimer; variable txtime 30000	;# inter-write timeout
Timer rxtimer; variable rxtime 5000	;# inter-read timeout
variable enttime 30000	;# entity inter-read timeout

# transmission state
variable satisfied; array set satisfied {}	;# array of requests satisfied
variable replies; array set replies {}	;# array of replies pending
variable pending 0			;# currently unsatisfied requests
variable gets 0

proc timeout {args} {
    if {!$::pending && !$::gets && ![array size ::replies]} {
	Debug.socket {Timeout $args - pending:$::pending gets:$::gets replies:[array size ::replies]} 2
	disconnect "Idle Time-out"
    }
}

# detach - force this thread to detach its socket
proc detach {sock} {
    variable prototype
    unset prototype	;# this means we can't continue without a connection
    ::thread::detach $sock
}

variable response	-1	;# last response sent

# responder --
#	deliver in-sequence transaction responses
#
# Arguments:
#
# Side Effects:
#	Send transaction responses to client
#	Possibly close socket

proc responder {} {
    variable replies
    variable sock
    Debug.http {RESPONDER $sock: [array names replies]} 4
    catch {txtimer cancel}

    if {![array size replies]} {
	# we've no more responses queued
	Debug.http {No replies} 4

	# turn off responder until there are more responses
	chan event $sock writable {}

	txtimer after $::txtime [list timeout "responder idle"]
	return	;# there are no pending replies - idle transmitter
    }

    # determine next available response in transaction# order
    set next [lindex [lsort -integer [array names replies]] 0]

    # ensure we don't send responses out of sequence
    variable response
    if {$next != ($response + 1)} {
	# something's blocking the response pipeline
	# we don't have a response for the next transaction.

	# we have to wait until all the preceding transactions
	# have something to send

	Debug.http {$next doesn't follow $response in [array names replies]}

	chan event $sock writable {}	;# disable responder
	txtimer after $::txtime [list timeout "responder pending"]
	return
    }

    # we're going to respond to the next transaction in trx order
    # unpack and consume the reply from replies queue
    lassign $replies($next) head content close

    # remove this response from the pending response structure
    set response $next	;# move to next response
    unset replies($next)	;# consume next reply

    # connection close required?
    # we only consider closing if all pending requests
    # have been satisfied.
    if {$close} {
	Debug.close {close requested on $sock - sending header}
	append head "Connection: close" \r\n	;# send a close just in case
	# Once the header's been sent, we're committed to closing
    }

    # send the header
    puts -nonewline $sock "$head\r\n"	;# send headers with terminating nl
    Debug.socket {SENT: $sock $head'} 4

    # send the content/file (if any)
    # note: we must *not* send a trailing newline, as this
    # screws up the content-length and confuses the client
    # which doesn't then pick up the next response
    # in the pipeline
    puts -nonewline $sock $content	;# send the content
    chan flush $sock
    Debug.socket {SENT content [string length $content] '$content'} 10
    incr ::pending -1		;# count one fewer request pending

    # close the connection - the client's been notified
    if {$close} {
	disconnect "Disconnect"
    } else {
	chan event $sock writable responder	;# keep trying to send replies
    }

    Debug.http {Sent: $response} 2
}

# expunge - remove metadata from reply dict
proc expunge {reply} {
    foreach n [dict keys $reply content-*] {
	dict unset reply $n
    }
    if {[dict exists $reply -content]} {
	dict unset reply -content	;# discard content
    }
    return $reply
}

# gzip_it - return reply with gzipped content
proc gzip_it {reply content} {
    if {[dict exists $reply -gzip]} {
	# permit cache to supply pre-gzipped content
	set content [dict get $reply -gzip]
    } else {
	# prepend a minimal gzip file header:
	# signature, deflate compression, no flags, mtime,
	# xfl=0, os=3
	set gzip [binary format "H*iH*" "1f8b0800" [clock seconds] "0003"]
	append gzip [zlib deflate $content 9]
	
	# append CRC and ISIZE fields
	append gzip [zlib crc32 $gzip]
	append gzip [binary format i [string length $content]]
	set content $gzip
	dict set reply -gzip $gzip
    }

    # convert the reply to gzipped content-encoding
    dict set reply content-encoding gzip
    dict set reply content-length [string length $content]

    return [list $reply $content]
}

# Send - queue up a transaction response
#
# Arguments:
#	code	list of response code and (optional) error message
#
# Side Effects:
#	queues the response for sending by method responder
proc send {reply {cacheit 1}} {
    Debug.http {[set x $reply; dict set x -content <ELIDED>; return ""]send: $x}

    set sock [dict get $reply -sock]

    # fetch transaction from the caller's identity
    if {![dict exists $reply -transaction]} {
	# can't Send reply: no -transaction associated with request
	Debug.error {Send discarded: no transaction ($reply)}
	return
    } elseif {[dict get $reply -generation] != $::generation} {
	# this reply belongs to an older, disconnected Httpd generation.
	# we must discard it, because it was directed to a different client!
	Debug.error {Send discarded: out of generation ([set x $reply; dict set x -content <ELIDED>; return $x]) != $::generation}
	return
    }
    set trx [dict get $reply -transaction]

    # discard duplicate responses
    if {[info exists ::satisfied($trx)]} {
	# a duplicate response has been sent - discard this
	# this could happen if a dispatcher sends a response,
	# then gets an error.
	Debug.error {Send discarded: duplicate ($reply)}
	return
    }

    # allow domains to set their own http header tags
    foreach {n v} [dict get? $reply -meta] {
	dict set reply $n $v
    }

    # handle Vary field
    if {[dict exists $reply -vary]} {
	if {[dict exists $reply -vary *]} {
	    dict set reply vary "*"
	} else {
	    dict set reply vary [join [dict keys [dict get $reply -vary]]]
	}
	dict unset reply -vary
    }

    set code [dict get $reply -code]

    # unpack and consume the reply from replies queue
    if {$code < 4} {
	# this was a tcl code, not an HTTP code
	set code 500
    }

    # set the informational error message
    if {[dict exists $reply -error]} {
	set errmsg [dict get $reply -error]
    }
    if {![info exists errmsg] || ($errmsg eq "")} {
	set errmsg [Http ErrorMsg $code]
    }

    if {$code >= 500} {
	# Errors are completely dynamic - no caching!
	set reply [Http NoCache $reply]
    }

    set header "HTTP/[dict get $reply -version] $code $errmsg\r\n"
    set close [expr {[dict get $reply -version] < 1.1}]	;# don't honour 1.0 keep-alives
    Debug.close {version [dict get $reply -version] implies close=$close}

    # format up the headers
    if {$code != 100} {
	append header "Date: [Http Now]" \r\n
	append header "Server: $::server_id" \r\n
    }

    # format up and send each cookie
    if {[dict exists $reply -cookies]} {
	foreach cookie [Cookies format4server [dict get $reply -cookies]] {
	    append header "set-cookie: $cookie\r\n"
	}
    }

    # ensure no content data is sent when it's illegal to do so
    if {[dict exists $reply -content]} {
	# there is content data
	if {[dict exists $reply -method]
	    && ([dict get $reply -method] eq "HEAD")} {
	    # All responses to the HEAD request method MUST NOT
	    # include a message-body.
	    set reply [expunge $reply]
	} else {
	    # 1xx (informational),
	    # 204 (no content),
	    # and 304 (not modified)
	    # responses MUST NOT include a message-body
	    switch -glob -- $code {
		204 - 304 - 1* {
		    set reply [expunge $reply]
		}

		default {
		    set content [dict get $reply -content]

		    # perform post-map on content.
		    # allows for string substitution of content
		    # according to the -map dict -
		    # e.g. [dict lappend reply -map %SESSION% $session]
		    # will work on content from cache, e.g.
		    if {[dict exists $reply -map]} {
			set map {}
			dict for {key val} [dict get $reply -map] {
			    lappend map $key [join $val]
			}
			set content [string map $map $content]
			dict unset reply -map	;# remove map - it's done
			catch {dict unset reply -gzip}	;# remove gzip form, if any.
		    }
		    
		    # handle encoding
		    if {[dict exists $reply accept-encoding]
			&& ![dict exists $reply content-encoding]} {
			foreach en [split [dict get $reply accept-encoding] ","] {
			    lassign [split $en ";"] en
			    set en [string trim $en]
			    if {$en in $::te_encodings} {
				switch $en {
				    "gzip" {
					lassign [gzip_it $reply $content] reply content
					break
				    }
				}
			    }
			}
		    }

		    dict set reply content-length [string length $content]
		}
	    }
	}
    } else {
	set content ""
    }

    # add in Auth header elements - TODO
    foreach challenge [dict get? $reply -auth] {
	append header "WWW-Authenticate: $challenge" \r\n
    }

    # now attend to caching.
    if {$cacheit && [dict exists $reply cache-control]} {
	set cacheable [split [dict get $reply cache-control] ,]
	foreach directive $cacheable {
	    set body [string trim [join [lassign [split $directive =] d] =]]
	    set d [string trim $d]
	    if {$d in {no-cache private}} {
		set cacheit 0
		break
	    }
	}
    }

    dict set reply etag "\"[::thread::id].[clock microseconds]\""

    if {[dict exists $reply content-type]} {
	# handle charset
	if {[dict exists $reply -charset]} {
	    set charset [dict get $reply -charset]
	} else {
	    set charset [encoding system]
	}
	dict append reply content-type "; charset=$charset"
    }

    # strip http fields which don't have relevance in response
    dict for {n v} $reply {
	set nl [string tolower $n]
	if {($nl ni {server date})
	    && [info exists ::Http::headers($nl)]
	    && ($::Http::headers($nl) ne "rq")} {
	    append header "$n: $v" \r\n
	}

	if {$nl eq "connection"} {
	    foreach ct [split $v ,] {
		if {[string trim $ct] eq "close"} {
		    Debug.close {Tagging $sock for closing because connection field requested it. '$v'}
		    set close 1
		}
	    }
	}
    }

    # record transaction reply and kick off the responder
    if {$close} {
	catch {chan event $sock readable {}}	;# we're not accepting more input
    }

    if {[dict exists $reply content-length] && ([dict get $reply content-length] != [string length $content])} {
	error "Content length [dict get $reply content-length] != [string length $content]"
    }

    if {![info exists content]} {
	set content ""	;# this shouldn't happen.
    }
    set ::replies($trx) [list $header $content $close]
    set ::satisfied($trx) 1	;# the request has been satisfied

    Debug.http {ADD TRANS: $header ([array names ::replies])}
    # response has been collected and is pending output
    if {[catch {chan event $::sock writable responder}]} {
	disconnect "Remote closed connection"
    }

    # handle bot
    if {[dict exists $reply -bot_change]} {
	# this is a newly detected bot - inform parent
	dict set enbot -bot [dict get $reply -bot]
	set ip [dict get $reply -ipaddr]
	if {$ip eq "127.0.0.1"
	    && [dict exists $reply x-forwarded-for]
	} {
	    set ip [lindex [split [dict get $reply x-forwarded-for] ,] 0]
	}
	dict set enbot -ipaddr $ip
	thread::send -async $::thread::parent [list Honeypot bot? $enbot]
    } else {
	# handle caching (under no circumstances cache bot replies)
	if {$cacheit} {
	    dict set reply -code $code
	    thread::send -async $::thread::parent [list Cache put $reply]
	}
    }
}

# disconnect - a fatal socket-level error has occurred
# close everything, report the failure to parent
proc disconnect {error {eo {}}} {
    foreach timer [Timer info instances] {
	$timer cancel
    }

    variable request
    Debug.socket {disconnect: '$error' ($request)}
    Debug.close {disconnecting: '$error' ($eo)}

    ;# remove socket
    if {[catch {close $::sock} r eo]} {
	Debug.close {closing error: '$r' ($eo)}
    }

    # inform parent of disconnect - this thread will now be recycled
    ::thread::send -async $::thread::parent [list ::Httpd::disconnect [::thread::id] $error $eo]

    array unset ::satisfied; array set ::satisfied {}	;# forget request state
    array unset ::replies; array set ::replies {}	;# forget pending replies
    catch {unset request}
    set ::gets 0
    set ::pending 0

    return -code return
}

# clean - clean up the request - remove all protocol elements
proc clean {} {
    variable request $::prototype
}

# handle - 
proc handle {req} {
    Debug.socket {handle: $req}

    catch {rxtimer cancel}
    chan event $::sock readable {}	;# suspend reading
    dict set req connection close
    send $req			;# send our own reply

    clean
    chan event $::sock readable get	;# resume reading
    return -code return 0
}

# we're finished reading the header - inform the parent that work is needed
proc got {req} {
    Debug.socket {got: $req}

    catch {rxtimer cancel}
    chan event $::sock readable {}	;# suspend reading

    # rename fields whose names are the same in request/response
    foreach n {cache-control} {
	if {[dict exists $req $n]} {
	    dict set req -$n [dict get $req $n]
	    dict unset req $n
	}
    }

    # fix up non-standard X-Forwarded-For field
    if {[dict exists $req x-forwarded-for]} {
	dict set req -x-forwarding [dict get? $req -ipaddr]
	dict set req -ipaddr [string trim [lindex [split [dict get $req x-forwarded-for] ,] 0]]
    }

    dict set req -transaction [incr ::transaction]

    # inform parent of parsing completion
    ::thread::send -async $::thread::parent [list ::Httpd::got [::thread::id] $req]

    clean
    chan event $::sock readable get	;# resume reading
    return -code return 0
}

# gzip - 
proc gzip {} {
    variable request
    dict set request -entity [zlib deflate [dict get $request -entity]]
}

# read the entity, informing parent when complete
proc identity {length} {
    variable request
    rxtimer cancel

    # read as much of the entity as is available
    dict set request -left [expr {$length - [string bytelength [dict get $request -entity]]}]
    dict append request -entity [read $::sock [dict get $::request -left]]

    if {[string bytelength [dict get $request -entity]] == $length} {
	chan event $::sock readable {}	;# disable reading
	# completed entity - invoke continuation
	foreach te [dict get $request -te] {
	    $te
	}
	got $request
    } else {
	rxtimer after $::enttime [list timeout "identity timeout"]
    }
}

proc chunk {} {
}

# Start reading an entity from the client.
# On completion use the supplied completion callback
proc entity {} {
    variable request
    if {[dict get $request -method] ne "POST"} {
	return 1 ;# not a post?  No entity available.
    }

    # rfc2616 4.3
    # The presence of a message-body in a request is signaled by the
    # inclusion of a Content-Length or Transfer-Encoding header field in
    # the request's headers.
    if {[dict exists $request transfer-encoding]} {
	set te [dict get $request transfer-encoding]

	# chunked 3.6.1
	# identity 3.6.2
	# gzip 3.5
	# compress 3.5
	# deflate 3.5
	set tels {}
	array set params {}
	variable te_encodings
	variable te_params
	foreach tel [split $te ,] {
	    set param [lassign [split $tel ";"] tel]
	    set tel [string trim $tel]
	    if {$tel ni $te_encodings} {
		# can't handle a transfer encoded entity
		handle [Http NotImplemented $request]
		# see 3.6 - 14.41 for transfer-encoding
		# 4.4.2 If a message is received with both a Transfer-EncodIing
		# header field and a Content-Length header field,
		# the latter MUST be ignored.
	    } else {
		lappend tels $tel
		set params($tel) [split $param ";"]
	    }
	}

	dict set request -te $tels
	dict set request -te_params [array get params]

	if {"chunked" in $tels} {

	    start_transfer
	    dict set request -entity "" ;# clear any old entity
	    chan event $::sock readable chunk

	    return
	} else {
	    # it's *got* to be an identity transfer - strip it
	    set idx [lsearch $tels "identity"] 
	    set tels [lreplace $tels $idx $idx]
	}
    } else {
	dict set request -te {}
    }

    # this is a content-length driven entity transfer
    if {![dict exists $request content-length]} {
	# 411 Length Required
	handle [Http Bad $request "Length Required" 411]
    }

    set length [dict get $request content-length]
    if {$length == 0} {
	dict set request -entity {}
	return 1 ;# the entity, length 0, is therefore already read
	# 14.13: Any Content-Length greater than
	# or equal to zero is a valid value.
    }

    # enforce server limits on Entity length
    variable maxentity
    if {($maxentity > 0) && ($length > $maxentity)} {
	# 413 "Request Entity Too Large"
	handle [Http Bad $request "Request Entity Too Large" 413]
    }

    # start the copy of POST data
    rxtimer after $::enttime [list timeout "entity timeout"]
    start_transfer
    dict set request -entity "" ;# clear any old entity
    chan event $::sock readable [list identity $length]

    return 0	;# we'll be handling the channel
}

proc start_transfer {} {
    variable request
    # start the transmission of POST entity, if necessary/possible
    if {([dict get $request -version] >= 1.1) && [dict exists $request expect]} {
	if {[string match *100-continue* [string tolower [dict get $request expect]]]} {
	    # the client wants us to tell it to continue
	    # before reading the body.
	    # Do so, then proceed to read
	    puts -nonewline $::sock "HTTP/1.1 100 Continue\r\n"
	}
    }
}

# Parse the entire header in {$req -header}
proc parse {} {
    variable request
    Debug.socket {parse: $request} 3
    set header [dict get $request -header]
    dict unset request -header

    # parse header body
    set key ""
    foreach line [lrange $header 1 end] {
	if {[string index $line 0] in " \t"} {
	    # header continuation line
	    # add to the key we're currently assembling
	    if {$key eq ""} {
		handle [Http Bad $request "malformed header line '$line'"]
	    }
	    dict append request $key " [string trim $line]"
	} else {
	    # this is a new field:value pair
	    set value [string trim [join [lassign [split $line ":"] key] ":"]]
	    set key [string tolower [string trim $key "- \t"]]

	    if {[dict exists $request $key]} {
		dict append request $key ",$value"
	    } else {
		dict set request $key $value
	    }

	    # limit size of each field
	    if {$::maxfield
		&& ([string length [dict get $request $key]] > $::maxfield)} {
		handle [Http Bad $request "Illegal header: '$line'"]
	    }
	}
    }

    # we have completely parsed the header body.

    # parse requestuest-line
    set line [lindex $header 0]
    #puts stderr "Header: $line"

    lassign [split $line] head(-method) head(-uri) head(-version)
    set head(-method) [string toupper $head(-method)]

    if {[string match HTTP/* $head(-version)]} {
	set head(-version) [lindex [split $head(-version) /] 1]

	# check URI length (per rfc2616 3.2.1
	# A server SHOULD return 414 (Requestuest-URI Too Long) status
	# if a URI is longer than the server can handle (see section 10.4.15).)
	if {$::maxurilen && ([string length $head(-uri)] > $::maxurilen)} {
	    # send a 414 back
	    handle [Http Bad $request "URI too long '$head(-uri)'" 414]
	}

	# record header data in request dict
	#set url [Url parse "http://$head(-uri)"]
	#puts stderr "got head: '$request', '[array get head]'"
	set request [dict merge $request [array get head]]
    } else {
	# Could check for FTP requestuests, etc, here...
	dict set request -error $line
	handle [Http Bad $request "Method not supported" 405]
    }

    # Send 505 for protocol != HTTP/1.0 or HTTP/1.1
    if {([dict get $request -version] != 1.1)
	&& ([dict get $request -version] != 1.0)} {
	handle [Http Bad $request "HTTP Version not supported" 505]
    }

    # ensure that the client sent a Host: if protocol requires it
    if {[dict exists $request host]} {
	if {[dict exists $request -host] && ([dict get $request -host] ne "")} {
	    # rfc 5.2 1 - a host header field must be ignored
	    # if request-line specified an absolute URL host/port
	    dict set request -host $::host
	    dict set request -port $::port
	    dict set request host [join {*}[list $host $port] :]
	} else {
	    # no absolute URL was specified by the request-line
	    # use the Host field to determine the host
	    foreach c [split [dict get $request host] :] f {host port} {
		dict set request -$f $c
	    }
	}
    } elseif {[dict get $request -version] > 1.0} {
	handle [Http Bad $request "HTTP 1.1 is required to send Host request"]
    } else {
	# HTTP 1.0 isn't required to send a Host request
	if {![dict exists $request -host]} {
	    # make sure the request has some idea of our host&port
	    dict set request -host $::host
	    dict set request -port $::port
	}
    }

    # rfc2616 14.10:
    # A system receiving an HTTP/1.0 (or lower-version) message that
    # includes a Connection header MUST, for each connection-token in this
    # field, remove and ignore any header field(s) from the message with
    # the same name as the connection-token.
    if {([dict get $request -version] < 1.1) && [dict exists $request connection]} {
	foreach token [split [dict get $request connection] ","] {
	    catch {dict unset request [string trim $token]}
	}
	dict unset request connection
    }

    # now parse the request-line URL
    set request [dict merge $request [Url parse "http://$head(-uri)"]]
    dict set request -url [Url url $request]

    # completed request header decode - now dispatch on the URL

    #puts stderr "PARSE: $request"
    if {[dict get $request -uri] eq "/error"} {
	error "Test background error handling"
    }

    # remove 'netscape extension' length= from if-modified-since
    if {[dict exists $request if-modified-since]} {
	dict set request if-modified-since [lindex [split [dict get $request if-modified-since] {;}] 0]
    }

    incr ::pending
    set ::gets 0
    switch -- [dict get $request -method] {
	POST {
	    if {![dict exists $request content-length]} {
		# Send 411 for missing Content-Length on POST requests
		handle [Http Bad $request "Length Required" 411]
	    } else {
		# read the entity
		#puts stderr "Entity: $request"
		if {[entity]} {
		    #puts stderr "Not Entity: $request"
		    got $request
		} else {
		    #puts stderr "yes Entity: $request"
		}
	    }
	}

	CONNECT {
	    # stop the bastard SMTP spammers
	    thread::send -async $::thread::parent [list Httpd block [dict get $request -ipaddr]]

	    handle [Http NotImplemented $request]
	    disconnect "Bastard Spammer"
	}

	default {
	    Debug.http {parse done: $request} 3
	    got $request
	}
    }
}

# get lines of header until it's complete
proc get {} {
    rxtimer cancel
    variable sock
    variable request

    incr ::gets

    Debug.socket {get: $request} 10
    
    if {[catch {chan gets $sock line} result eo]} {
	disconnect $request $eo	;# inform parent that we're done
    }

    if {$result == -1} {
	catch {chan event $sock readable {}}	;# completed reading
	if {[chan eof $sock]} {
	    # remote end closed - just forget it
	    disconnect "Remote closed connection" $request 
	} else {
	    if {$::maxline && ([chan pending input $sock] > $::maxline)} {
		handle [Http Bad $request "Line too long"]
	    }
	}

	rxtimer after $::enttime [list timeout "pre-read timeout"]
	return
    }
    
    if {[string trim $line] eq ""} {
	if {[dict exists $request -header]} {
	    # \n terminates the header - go parse it
	    chan event $sock readable {}	;# completed reading
	    parse
	} else {
	    return	;# this is a leading empty line, ignore it:
	    # rfc2616 4.1: In the interest of robustness,
	    # servers SHOULD ignore any empty line(s)
	    # received where a Request-Line is expected.
	}
    } else {
	# accumulate header lines
	rxtimer after $::rxtime [list timeout "inter-read timeout"]
	dict lappend request -header $line
	if {$::maxhead && ([llength [dict get $request -header]] > $::maxhead)} {
	    handle [Http Bad $request "Header too Large"]
	}
    }
}

# Parent thread will call connect with the pro-forma request
proc connect {req vars socket} {
    Debug.socket {[::thread::id] connect $req $vars $socket}

    array unset ::satisfied	;# forget request state
    array unset ::replies	;# forget pending replies
    set ::pending 0		;# no pending requests

    if {$socket == $::sock} {
	dict set req -generation $::generation
    } else {
	dict set req -generation [incr ::generation]
	set ::transaction -1
	set ::sock $socket
	set ::response -1
    }
    variable {*}$vars	;# instantiate variables
    dict set req -worker [::thread::id]
    dict set req -entity {}

    variable prototype $req	;# set a clean prototype
    variable request $req	;# remember the request

    rxtimer after $::txtime [list timeout "first-read timeout"]
    chan event $socket readable get
    Debug.socket {[::thread::id] connected}
}

Debug off close 10
# now we're able to process commands
#puts stderr "Started Httpd Worker [::thread::id]"
thread::wait
#puts stderr "~Thread: [thread::id]"
