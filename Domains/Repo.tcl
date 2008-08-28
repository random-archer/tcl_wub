# Repo -
#
# A domain to present a file system as a series of URLs

package require Debug
Debug on repo 10

package require tar
package require fileutil
package require Html
package require Report
package require Form
package require Mime
package require jpeg
package require jQ

package provide Repo 1.0

# TODO - handle dangling softlinks in dirlist
# TODO - some kind of permissions system

namespace eval Repo {
    variable dirparams {
	sortable 1
	evenodd 0
	class table
	tparam {title "Registry for this class"}
	hclass header
	hparam {title "click to sort"}
	thparam {class thead}
	fclass footer
	tfparam {class tfoot}
	rclass row
	rparam {title row}
	eclass el
	eparam {}
	footer {}
    }
    variable dirtime "%Y %b %d %T"
    variable icon_size 24
    variable icons /icons/

    proc dir {req path args} {
	Debug.repo {dir $path $args}
	dict set files .. [list name [<a> href .. ..] type parent]
	variable dirtime
	variable icon_size
	variable icons
	foreach file [glob -nocomplain -directory $path *] {
	    set name [file tail $file]
	    if {![regexp {^([.].*)|(.*~)|(\#.*)$} $name]} {
		set type [Mime type $file]
		if {$type eq "multipart/x-directory"} {
		    set type directory
		    append name /
		}
		set title [<a> href $name $name]
		set del [<a> href $name?op=del title "click to delete" [<img> height $icon_size src ${icons}remove.gif]]
		dict set files $name [list name $title modified [clock format [file mtime $file] -format $dirtime] size [file size $file] type $type op $del]
	    }
	}

	set suffix [dict get $req -suffix]
	append content [<h1> "[dict get $args title] - [string trimright $suffix /]"] \n

	variable dirparams
	append content [Report html $files {*}$dirparams headers {name type modified size op}] \n
	if {[dict exists $args tar] && [dict get $args tar]} {
	    append content [<p> "[<a> href [string trimright [dict get $req -path] /] Download] directory as a POSIX tar archive."] \n
	}

	if {[dict exists $args docprefix]} {
	    append content [<p> [<a> href [dict get $args docprefix]$suffix "Read Documentation"]] \n
	}

	if {[dict exists $args upload]} {
	    append content [<form> create action . {
		[<text> subdir label [<submit> submit "Create"] size 20 ""]
		[<hidden> op create]
	    }] \n

	    append content [<form> upload action . enctype "multipart/form-data" {
		[<file> file label [<submit> submit "Upload"] class multi]
		[<hidden> op upload]
	    }] \n
	    set req [jQ multifile $req]	;# make upload form a multifile
	}

	dict set req -content $content
	dict set req content-type x-text/html-fragment
	set req [jQ tablesorter $req .sortable]

	return $req
    }

    proc upload {r Q args} {
	Debug.repo {upload ARGS: $args}
	dict with args {}	;# extract dict vars
	foreach v {r max path Q} {
	    catch {dict unset Q $v}
	}
	set Q [dict filter $Q key {[a-zA-Z]*}]
	dict with Q {}

	# process upload and mime type
	set messages {}
	foreach f [info vars file*] {
	    # extract meaning from file upload
	    set content [set $f]
	    if {$content eq ""} continue
	    set metadata [Query metadict [dict get $r -Query] $f]
	    Debug.repo {+add Q: $metadata}

	    set name [Dict get? $metadata filename]
	    if {$name eq ""} {
		set name [clock seconds]
	    }

	    if {[string length $content] > $max} {
		lappend messages "file '$name' is too long"
		continue
	    }
	    set name [::fileutil::jail $path $name]
	    ::fileutil::writeFile -encoding binary -translation binary -- $name $content
	    Debug.repo {upload $name}
	}

	if {$messages ne ""} {
	    return [Http Forbidden $r [<p> "Some uploads failed: "][join $messages \n]]
	} else {
	    # multiple adds - redirect to parent
	    return [Http Redirect $r [dict get $r -url]]	;# redirect to parent
	}
    }

    proc _do {inst req} {
	dict with inst {}	;# instance vars

	if {[dict exists $req -suffix]} {
	    # caller has munged path already
	    set suffix [dict get $req -suffix]
	} else {
	    # assume we've been parsed by package Url
	    # remove the specified prefix from path, giving suffix
	    set path [dict get $req -path]
	    set suffix [Url pstrip $prefix $path]
	    if {($suffix ne "/") && [string match "/*" $suffix]} {
		# path isn't inside our domain suffix - error
		return [Http NotFound $req]
	    }
	    dict set req -suffix $suffix
	}

	dict set req -title "$title - [string trimright $suffix /]"
	set ext [file extension $suffix]
	set path [file normalize [file join $mount [string trimleft $suffix /]]]
	#dict set req -path $path
	
	# unpack query response
	set Q [Query parse $req]
	dict set req -Query $Q
	set Q [Query flatten $Q]

	Debug.repo {suffix:$suffix path:$path req path:[dict get $req -path] mount:$mount Q:$Q}

	switch -- [Dict get? $Q op] {
	    del {
		# move this file out of the way
		set dir [file dirname $path]
		set fn [file tail $path]
		set vers 0 ;while {[file exists [file join $dir .del-$fn.$vers]]} {incr vers}
		Debug.repo {del: $path -> [file join $dir .del-$fn.$vers]}
		file rename $path [file join $dir .del-$fn.$vers]
		return [Http Redir $req .]
	    }

	    create {
		# create a subdirectory
		set subdir [::fileutil::jail $path [dict get $Q subdir]]
		set relpath [file join [lrange [file split [::fileutil::relativeUrl $path $subdir]] 1 end]]/
		Debug.repo {create: $path $subdir - $relpath}
		file mkdir $subdir
		return [Http Redir $req $relpath]
	    }

	    upload {
		# upload some files
		return [upload $req $Q path $path {*}$inst]
	    }
	}
	
	if {$ext ne "" && [file tail $suffix] eq $ext} {
	    # this is a file name like '.tml'
	    return [Http NotFound $req [<p> "File '$suffix' has illegal name."]]
	}

	if {![file exists $path]} {
	    dict lappend req -depends $path	;# cache notfound
	    return [Http NotFound $req [<p> "File '$suffix' doesn't exist."]]
	}

	# handle conditional request
	if {[dict exists $req if-modified-since]
	    && (![dict exists $req -dynamic] || ![dict get $req -dynamic])
	} {
	    set since [Http DateInSeconds [dict get $req if-modified-since]]
	    if {[file mtime $path] <= $since} {
		Debug.repo {NotModified: $path - [Http Date [file mtime $path]] < [dict get $req if-modified-since]}
		Debug.repo {if-modified-since: not modified}
		return [Http NotModified $req]
	    }
	}
	
	Debug.repo {dispatch '$path' $req}
	
	Debug.repo {Found file '$path' of type [file type $path]}
	dict lappend req -depends $path	;# remember cache dependency on dir
	switch -- [file type $path] {
	    link -
	    file {
		dict set req -raw 1	;# no transformations
		return [Http Ok [Http NoCache $req] [::fileutil::cat -encoding binary -translation binary -- $path] [Mime type $path]]
	    }
	    
	    directory {
		# if a directory reference doesn't end in /, redirect.
		set rpath [dict get $req -path]
		if {[string index $rpath end] ne "/"} {
		    if {$tar} {
			# return the whole dir in one hit as a tar file
			set dir [pwd]
			cd [file dirname $path]
			set tname /tmp/tar[clock seconds]
			::tar::create $tname $suffix
			set content [::fileutil::cat -encoding binary -translation binary -- $tname]
			cd $dir
			return [Http CacheableContent [Http Cache $req $expires] [file mtime $path] $content application/x-tar]
		    } else {
			# redirect to the proper name
			dict set req -path "$rpath/"
			return [Http Redirect $req [Url uri $req]]
		    }
		}

		if {$index ne "" && [file exists [file join $path $index]]} {
		    # return the specified index file
		    set index [file join $path $index]
		    return [Http Ok [Http NoCache $req] [::fileutil::cat -encoding binary -translation binary -- $index] x-text/html-fragment]
		} else {
		    # return a pretty table
		    return [Http Ok [Http NoCache [dir $req $path {*}$inst]]]
		}

		dict set req -raw 1	;# no transformations
		return [Http Ok [Http NoCache $req] [::fileutil::cat -encoding binary -translation binary -- $index] [Mime type $path]]
	    }
	    
	    default {
		dict lappend req -depends $path	;# cache notfound
		return [Http NotFound $req [<p> "File '$suffix' is of illegal type [file type $path]"]]
	    }
	}
    }

    proc init {cmd prefix mount args} {
	set prefix /[string trim $prefix /]/
	set args [dict merge [list prefix $prefix mount $mount expires 0 tar 0 index index.html max [expr {1024 * 1024}] title Repo] $args]
	set cmd [uplevel 1 namespace current]::$cmd
	namespace ensemble create \
	    -command $cmd -subcommands {} \
	    -map [list do [list _do $args]]
	return $cmd
    }

    namespace export -clear *
    namespace ensemble create -subcommands {}
}
