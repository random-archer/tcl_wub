#! /usr/bin/env tclsh

if {0} {
    # this will run Wub under the experimental Package facility
    lappend auto_path [file dirname [pwd]]/Utilities/
    package require Package	;# start the cooption of [package]
}
#lappend auto_path [pwd]
set auto_path [list [pwd] {*}$auto_path]
package require Site

# Initialize Site
set siteconf $::env(HOME)/.wub/site.config
Site init home [file normalize [file dirname [info script]]] config $siteconf debug 10 {*}$argv

# Start Site Server(s)
Site start 
