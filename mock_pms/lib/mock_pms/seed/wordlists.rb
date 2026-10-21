# frozen_string_literal: true

module MockPms
  module Seed
    # Fixed synthetic word lists. The seed draws from these with its seeded Random,
    # so output depends only on (seed, anchor_date) — never on a gem's version.
    module Wordlists
      FIRST_NAMES = %w[
        Avery Blake Carmen Dana Elena Felix Grace Hector Iris Jonah Kira Luis Maya Nolan Olivia Pablo
        Quinn Rosa Samir Tessa Uriel Vera Wade Ximena Yusuf Zoe Adrian Bianca Caleb Delia Emil Fiona
        Gavin Hana Isaac Jada Kofi Lena Marco Nadia
      ].freeze

      LAST_NAMES = %w[
        Alvarez Brooks Castillo Dawson Ellison Flores Garza Holt Ibarra Jensen Keller Lozano Mercer
        Navarro Ortega Pruitt Quintero Ramos Salazar Tran Underwood Vargas Whitaker Xu Young Zamora
        Abbott Benson Cortez Duran Espinoza Fischer Guerra Hale Ingram Juarez Kemp Lucero Moreno Nash
      ].freeze

      STREETS = [
        "Live Oak", "Pecan", "Mesquite", "Cedar", "Bluebonnet", "Juniper", "Sycamore", "Agave", "Cypress",
        "Magnolia", "Willow", "Laurel", "Primrose", "Larkspur", "Sotol", "Yucca", "Hackberry", "Redbud",
        "Persimmon", "Mockingbird"
      ].freeze

      STREET_TYPES = %w[St Ave Dr Ln Ct Trl Way Cv].freeze

      CITIES = [
        %w[Austin 787], ["Round Rock", "786"], %w[Pflugerville 786], ["Cedar Park", "786"], %w[Georgetown 786],
        ["San Marcos", "786"], %w[Kyle 786], %w[Leander 786]
      ].freeze

      OPERATORS = [
        { name: "Lone Star Rentals", login: "lonestar", properties: 25 },
        { name: "Prairie Homes", login: "prairie", properties: 15 },
        { name: "Bluebonnet Property Co", login: "bluebonnet", properties: 10 }
      ].freeze
    end
  end
end
