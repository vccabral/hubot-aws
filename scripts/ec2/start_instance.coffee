# Description:
#   Ensures the provided instances are started
#
# Commands:
#   hubot ec2 start <instance_id> [<instance_id> ...]
#
# Notes:
#   instance_id : [required] The ID of one or more instances to tag. For example, i-0acec691.
#   --dry-run  : [optional] Checks whether the api request is right. Recommend to set before applying to real asset.

util = require 'util'

getArgParams = (arg) ->
  dry_run = if arg.match(/--dry-run/) then true else false

  return {dry_run: dry_run}

module.exports = (robot) ->
  robot.respond /ec2 start(.*)$/i, (msg) ->
    unless require('../../auth.coffee').canAccess(robot, msg.envelope.user)
      msg.send "You cannot access this feature. Please contact with admin"
      return

    arg_value = msg.match[1]
    arg_params = getArgParams(arg_value)

    instances = []
    for av in arg_value.split /\s+/
      if av and not av.match(/^--/)
        instances.push(av)

    dry_run = arg_params.dry_run

    if instances.length < 1
      msg.send "One or more instance_ids are required"
      return

    msg.send "Starting instances=[#{instances}] dry-run=#{dry_run}..."

    params =
      InstanceIds: instances

    if dry_run
      msg.send util.inspect(params, false, null)
      return

    ec2 = require('../../ec2.coffee')

    ec2.startInstances params, (err, res) ->
      if err
        msg.send "Error: #{err}"
      else
       msg.send "Success! The instances are running"
       msg.send util.inspect(res, false, null)
